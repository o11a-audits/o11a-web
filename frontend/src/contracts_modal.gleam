import audit_data
import dommel
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import icons
import modal
import plinth/browser/element
import plinth/browser/event
import search
import snag

// ============================================================================
// Contracts Modal State
// ============================================================================

pub type ContractsModalState {
  ContractsModalState(
    all_contracts: List(audit_data.ContractMetadata),
    filtered_contracts: List(audit_data.ContractMetadata),
    selected_index: Int,
    current_preview_topic_id: Option(String),
    audit_name: String,
  )
}

// ============================================================================
// FFI Bindings for State Management
// ============================================================================

@external(javascript, "./mem_ffi.mjs", "get_contracts_modal_state")
fn get_contracts_modal_state() -> Result(ContractsModalState, Nil)

@external(javascript, "./mem_ffi.mjs", "set_contracts_modal_state")
fn set_contracts_modal_state(state: ContractsModalState) -> Nil

@external(javascript, "./mem_ffi.mjs", "clear_contracts_modal_state")
fn clear_contracts_modal_state() -> Nil

// Initialize state in Gleam, not JavaScript
fn init_contracts_modal_state() -> Nil {
  set_contracts_modal_state(ContractsModalState(
    all_contracts: [],
    filtered_contracts: [],
    selected_index: 0,
    current_preview_topic_id: None,
    audit_name: "",
  ))
}

// ============================================================================
// Helper Functions
// ============================================================================

fn get_at(list: List(a), index: Int) -> Result(a, Nil) {
  list
  |> list.drop(index)
  |> list.first
}

fn get_current_search_query() -> String {
  case dommel.query_selector("#contracts-modal .modal-search-input") {
    Ok(input) ->
      case dommel.value(input) {
        Ok(q) -> q
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

// ============================================================================
// Two-Pane Layout Creation
// ============================================================================

fn create_two_pane_layout(
  container: element.Element,
  state: ContractsModalState,
) -> Nil {
  // Append container size styles to existing styles (preserves modal shadow/border)
  let _ =
    container
    |> dommel.add_style("height: 60ch; display: flex; flex-direction: row;")

  // Left column (search + list)
  let left_column =
    dommel.new_div()
    |> dommel.set_style(
      "display: flex; flex-direction: column; border-right: 1px solid var(--color-body-border);",
    )

  // Search input container
  let search_container =
    dommel.new_div()
    |> dommel.set_style(
      "padding: 0.5rem; border-bottom: 1px solid var(--color-body-border);",
    )

  let search_input =
    dommel.new_input()
    |> dommel.set_type("text")
    |> dommel.set_class("modal-search-input")
    |> dommel.set_placeholder("Search contracts...")
    |> dommel.set_style(
      "width: 100%; padding: 0.5rem; background: var(--color-code-bg); color: var(--color-body-text); border: 1px solid var(--color-body-border); border-radius: 4px; font-size: 14px; box-sizing: border-box;",
    )
    |> dommel.add_event_listener("input", fn(e) {
      case get_contracts_modal_state() {
        Ok(state) -> {
          case event.target(e) {
            target -> {
              case dommel.cast(target) {
                Ok(elem) -> {
                  case dommel.value(elem) {
                    Ok(query) -> handle_search_input(query, state)
                    Error(_) -> Nil
                  }
                }
                Error(_) -> Nil
              }
            }
          }
        }
        Error(_) -> Nil
      }
    })
    |> dommel.add_event_listener("focus", fn(_e) { modal.set_input_context() })
    |> dommel.add_event_listener("blur", fn(_e) { modal.clear_input_context() })

  let _ = search_container |> dommel.append_child(search_input)

  // Left pane (contract list)
  let left_pane =
    dommel.new_div()
    |> dommel.set_class("modal-left-pane")
    |> dommel.set_style(
      "width: 40ch; overflow-y: auto; background: var(--color-code-bg); padding: 0.5rem; flex: 1;",
    )

  let _ = left_column |> dommel.append_child(search_container)
  let _ = left_column |> dommel.append_child(left_pane)

  // Right pane (preview)
  let right_pane =
    dommel.new_div()
    |> dommel.set_class("modal-right-pane")
    |> dommel.set_style(
      "width: 40ch; overflow-y: auto; background: var(--color-code-bg); padding: 1rem;",
    )
    |> dommel.set_inner_html("Loading...")

  let _ = container |> dommel.append_child(left_column)
  let _ = container |> dommel.append_child(right_pane)

  // Show loading message initially (contracts will be rendered when loaded)
  case list.is_empty(state.all_contracts) {
    True -> {
      let _ =
        left_pane
        |> dommel.set_inner_html(
          "<div style='color: var(--color-body-text); padding: 1rem;'>Loading contracts...</div>",
        )
      Nil
    }
    False -> {
      // Render contracts if already loaded
      render_contract_list(state.filtered_contracts, state.selected_index, "")
    }
  }

  Nil
}

// ============================================================================
// Rendering Functions
// ============================================================================

fn render_contract_list(
  contracts: List(audit_data.ContractMetadata),
  selected_index: Int,
  search_query: String,
) -> Nil {
  case dommel.query_selector("#contracts-modal .modal-left-pane") {
    Ok(list_container) -> {
      // Clear existing content
      let _ = list_container |> dommel.set_inner_html("")

      case list.is_empty(contracts) {
        True -> {
          let empty_msg =
            dommel.new_div()
            |> dommel.set_inner_text("No contracts match filter")
            |> dommel.set_style("color: var(--color-body-text); padding: 1rem;")

          let _ = list_container |> dommel.append_child(empty_msg)
          Nil
        }
        False -> {
          // Render each contract
          contracts
          |> list.index_map(fn(contract, idx) {
            let is_selected = idx == selected_index
            let bg_color = case is_selected {
              True -> "var(--color-code-selection-bg)"
              False -> "transparent"
            }

            let item =
              dommel.new_div()
              |> dommel.set_attribute("data-index", int.to_string(idx))
              |> dommel.set_style(
                "padding: 0.5rem; cursor: pointer; background: "
                <> bg_color
                <> "; color: var(--color-body-text); border-radius: 4px; margin-bottom: 0.25rem;",
              )

            // Contract row: icon + name + kind
            let name_container =
              dommel.new_div()
              |> dommel.set_style(
                "display: flex; align-items: center; gap: 0.5rem;",
              )

            // Add icon based on contract kind
            let icon_svg = case contract.kind {
              audit_data.Contract -> icons.file_braces
              audit_data.Interface -> icons.file_sliders
              audit_data.Library -> icons.file_exclamation
              audit_data.Abstract -> icons.file_question
            }

            let icon_container =
              dommel.new_span()
              |> dommel.set_style(
                "display: flex; align-items: center; flex-shrink: 0;",
              )
              |> dommel.set_inner_html(icon_svg)

            // Highlight matching search term in contract name
            let highlighted_name =
              search.highlight_match(contract.name, search_query)

            let name_span =
              dommel.new_span()
              |> dommel.set_inner_html(highlighted_name)

            let kind_span =
              dommel.new_span()
              |> dommel.set_inner_text(audit_data.contract_kind_to_string(
                contract.kind,
              ))
              |> dommel.set_style("font-size: 0.85rem; opacity: 0.7;")

            let _ = name_container |> dommel.append_child(icon_container)
            let _ = name_container |> dommel.append_child(name_span)
            let _ = name_container |> dommel.append_child(kind_span)
            let _ = item |> dommel.append_child(name_container)
            let _ = list_container |> dommel.append_child(item)

            item
          })
          |> list.each(fn(_) { Nil })

          Nil
        }
      }
    }
    Error(_) -> Nil
  }
}

fn render_preview(html: String) -> Nil {
  case dommel.query_selector("#contracts-modal .modal-right-pane") {
    Ok(preview) -> {
      let _ = preview |> dommel.set_inner_html(html)
      Nil
    }
    Error(_) -> Nil
  }
}

fn render_preview_error(error: String) -> Nil {
  render_preview("Error loading preview:<br><br>" <> error)
}

// ============================================================================
// Preview Loading with Race Condition Protection
// ============================================================================

fn load_preview(audit_name: String, topic: audit_data.Topic) -> Nil {
  // Update state to track current preview
  case get_contracts_modal_state() {
    Ok(state) -> {
      set_contracts_modal_state(
        ContractsModalState(..state, current_preview_topic_id: Some(topic.id)),
      )

      // Show loading indicator
      render_preview("Loading preview...")

      // Fetch source text
      audit_data.with_source_text(audit_name, topic, fn(result) {
        // Check if this is still the current selection
        case get_contracts_modal_state() {
          Ok(current_state) -> {
            case current_state.current_preview_topic_id {
              Some(current_topic_id) if current_topic_id == topic.id -> {
                // Still current, render it
                case result {
                  Ok(text) -> render_preview(text)
                  Error(err) -> render_preview_error(snag.line_print(err))
                }
              }
              _ -> {
                // User moved on, ignore this callback
                Nil
              }
            }
          }
          Error(_) -> Nil
        }
      })
    }
    Error(_) -> Nil
  }
}

// ============================================================================
// Event Handlers
// ============================================================================

fn handle_search_input(query: String, state: ContractsModalState) -> Nil {
  let filtered =
    search.filter(state.all_contracts, query, fn(contract) { contract.name })

  // Update state
  set_contracts_modal_state(
    ContractsModalState(
      ..state,
      filtered_contracts: filtered,
      selected_index: 0,
    ),
  )

  // Re-render list with search highlighting
  render_contract_list(filtered, 0, query)

  // Load preview for first item if any
  case list.first(filtered) {
    Ok(contract) -> load_preview(state.audit_name, contract.topic)
    Error(_) -> Nil
  }
}

fn handle_keydown(
  e: event.Event(event.UIEvent(event.KeyboardEvent)),
  state: ContractsModalState,
) -> Nil {
  let list_length = list.length(state.filtered_contracts)

  case event.key(e) {
    "Escape" -> {
      event.prevent_default(e)
      modal.close_modal(get_modal_config(state.audit_name))
    }

    "ArrowDown" if list_length > 0 -> {
      event.prevent_default(e)
      let new_index = case state.selected_index + 1 >= list_length {
        True -> 0
        False -> state.selected_index + 1
      }

      set_contracts_modal_state(
        ContractsModalState(..state, selected_index: new_index),
      )

      let search_query = get_current_search_query()
      render_contract_list(state.filtered_contracts, new_index, search_query)

      case get_at(state.filtered_contracts, new_index) {
        Ok(contract) -> load_preview(state.audit_name, contract.topic)
        Error(_) -> Nil
      }
    }

    "ArrowUp" if list_length > 0 -> {
      event.prevent_default(e)
      let new_index = case state.selected_index - 1 < 0 {
        True -> list_length - 1
        False -> state.selected_index - 1
      }

      set_contracts_modal_state(
        ContractsModalState(..state, selected_index: new_index),
      )

      let search_query = get_current_search_query()
      render_contract_list(state.filtered_contracts, new_index, search_query)

      case get_at(state.filtered_contracts, new_index) {
        Ok(contract) -> load_preview(state.audit_name, contract.topic)
        Error(_) -> Nil
      }
    }

    "Enter" if list_length > 0 -> {
      event.prevent_default(e)
      // Future: navigate to contract
      modal.close_modal(get_modal_config(state.audit_name))
    }

    _ -> Nil
  }
}

// ============================================================================
// Modal Configuration
// ============================================================================

fn get_modal_config(
  _audit_name: String,
) -> modal.ModalConfig(ContractsModalState) {
  modal.ModalConfig(
    modal_id: "contracts-modal",
    render_content: create_two_pane_layout,
    on_keydown: handle_keydown,
    init_state: init_contracts_modal_state,
    get_state: get_contracts_modal_state,
    clear_state: clear_contracts_modal_state,
  )
}

// ============================================================================
// Public API
// ============================================================================

pub fn open(audit_name: String) -> Nil {
  let config = get_modal_config(audit_name)

  // Check if modal already exists and has contracts loaded
  case dommel.query_selector("#contracts-modal") {
    Ok(_existing_modal) -> {
      // Modal already exists, just focus the input
      case dommel.query_selector("#contracts-modal .modal-search-input") {
        Ok(input) -> {
          let _ = input |> dommel.focus()
          Nil
        }
        Error(_) -> Nil
      }
    }
    Error(_) -> {
      // Modal doesn't exist, create it and fetch contracts
      modal.open_modal(config, fn() {
        // Focus the search input after modal is opened
        case dommel.query_selector("#contracts-modal .modal-search-input") {
          Ok(input) -> {
            let _ = input |> dommel.focus()
            Nil
          }
          Error(_) -> Nil
        }

        // Fetch contracts and initialize (after modal DOM is ready)
        audit_data.with_audit_contracts(audit_name, fn(result) {
          on_contracts_loaded(result, audit_name)
        })
      })
    }
  }
}

fn on_contracts_loaded(
  result: Result(List(audit_data.ContractMetadata), snag.Snag),
  audit_name: String,
) -> Nil {
  case result {
    Error(err) -> {
      // Display error in list pane
      case dommel.query_selector("#contracts-modal .modal-left-pane") {
        Ok(list_container) -> {
          let _ =
            list_container
            |> dommel.set_inner_html(
              "<div style='color: var(--color-body-text); padding: 1rem;'>Error loading contracts:<br><br>"
              <> snag.line_print(err)
              <> "</div>",
            )
          Nil
        }
        Error(_) -> Nil
      }

      // Show error in preview pane
      render_preview_error(snag.line_print(err))
    }

    Ok(contracts) -> {
      case list.is_empty(contracts) {
        True -> {
          // Treat empty list as error
          case dommel.query_selector("#contracts-modal .modal-left-pane") {
            Ok(list_container) -> {
              let _ =
                list_container
                |> dommel.set_inner_html(
                  "<div style='color: var(--color-body-text); padding: 1rem;'>No contracts found</div>",
                )
              Nil
            }
            Error(_) -> Nil
          }
          render_preview_error("No contracts available")
        }

        False -> {
          // Update modal state
          set_contracts_modal_state(ContractsModalState(
            all_contracts: contracts,
            filtered_contracts: contracts,
            selected_index: 0,
            current_preview_topic_id: None,
            audit_name: audit_name,
          ))

          // Render contract list (no search query initially)
          render_contract_list(contracts, 0, "")

          // Load preview for first contract
          case list.first(contracts) {
            Ok(contract) -> load_preview(audit_name, contract.topic)
            Error(_) -> Nil
          }
        }
      }
    }
  }
}
