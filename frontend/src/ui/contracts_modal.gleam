import audit_data
import dromel
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import plinth/browser/element
import plinth/browser/event
import search
import snag
import ui/elements
import ui/icons
import ui/modal
import ui/topic_view

// ============================================================================
// Contracts Modal State
// ============================================================================

pub type ContractsModalState {
  ContractsModalState(
    all_contracts: List(audit_data.TopicMetadata),
    filtered_contracts: List(audit_data.TopicMetadata),
    selected_index: Int,
    current_preview_topic_id: Option(String),
    search_query: String,
    left_pane: element.Element,
    right_pane: element.Element,
  )
}

// ============================================================================
// FFI Bindings for State Management
// ============================================================================

@external(javascript, "../mem_ffi.mjs", "get_contracts_modal_state")
fn get_contracts_modal_state() -> Result(ContractsModalState, Nil)

@external(javascript, "../mem_ffi.mjs", "set_contracts_modal_state")
fn set_contracts_modal_state(state: ContractsModalState) -> Nil

fn init_contracts_modal_state(
  left_pane: element.Element,
  right_pane: element.Element,
) -> Nil {
  set_contracts_modal_state(ContractsModalState(
    all_contracts: [],
    filtered_contracts: [],
    selected_index: 0,
    current_preview_topic_id: None,
    search_query: "",
    left_pane: left_pane,
    right_pane: right_pane,
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

// ============================================================================
// Modal Mounting
// ============================================================================

fn mount_contracts_modal(container: element.Element) -> Nil {
  // Append container size styles to existing styles (preserves modal shadow/border)
  let _ =
    container
    |> dromel.add_style("height: 60ch; display: flex; flex-direction: row;")

  // Left column (search + list)
  let left_column =
    dromel.new_div()
    |> dromel.set_style(
      "display: flex; flex-direction: column; border-right: 1px solid var(--color-body-border);",
    )

  // Search input container
  let search_container =
    dromel.new_div()
    |> dromel.set_style(
      "padding: 0.5rem; border-bottom: 1px solid var(--color-body-border);",
    )

  let search_input =
    dromel.new_input()
    |> dromel.set_type("text")
    |> dromel.set_class(elements.modal_search_input_class)
    |> dromel.set_placeholder("Search contracts...")
    |> dromel.set_style(
      "width: 100%; padding: 0.5rem; background: var(--color-body-bg); color: var(--color-body-text); border: none; font-size: 14px; box-sizing: border-box;",
    )
    |> dromel.add_event_listener("input", fn(e) {
      case get_contracts_modal_state() {
        Ok(state) -> {
          case dromel.cast(event.target(e)) {
            Ok(elem) -> {
              case dromel.value(elem) {
                Ok(query) -> handle_search_input(query, state)
                Error(_) -> Nil
              }
            }
            Error(_) -> Nil
          }
        }
        Error(_) -> Nil
      }
    })
    |> dromel.add_event_listener("focus", fn(_e) { modal.set_input_context() })
    |> dromel.add_event_listener("blur", fn(_e) { modal.clear_input_context() })

  let _ = search_container |> dromel.append_child(search_input)

  // Left pane (contract list)
  let left_pane =
    dromel.new_div()
    |> dromel.set_class(elements.modal_left_pane_class)
    |> dromel.append_class(elements.source_container_class)
    |> dromel.set_style(
      "background: var(--color-body-bg); padding: 0.5rem; flex: 1;",
    )
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text); padding: 1rem;'>Loading contracts...</div>",
    )

  let _ = left_column |> dromel.append_child(search_container)
  let _ = left_column |> dromel.append_child(left_pane)

  // Right pane (preview)
  let right_pane =
    dromel.new_div()
    |> dromel.set_class(elements.modal_right_pane_class)
    |> dromel.append_class(elements.source_container_class)
    |> dromel.set_style("background: var(--color-code-bg); padding: 1rem;")
    |> dromel.set_inner_html("Loading...")

  let _ = container |> dromel.append_child(left_column)
  let _ = container |> dromel.append_child(right_pane)

  // Initialize state with element references
  init_contracts_modal_state(left_pane, right_pane)
}

// ============================================================================
// Rendering Functions
// ============================================================================

fn render_contract_list(
  list_container: element.Element,
  contracts: List(audit_data.TopicMetadata),
  selected_index: Int,
  search_query: String,
) -> Nil {
  // Clear existing content
  let _ = list_container |> dromel.set_inner_html("")

  case list.is_empty(contracts) {
    True -> {
      let empty_msg =
        dromel.new_div()
        |> dromel.set_inner_text("No contracts match filter")
        |> dromel.set_style("color: var(--color-body-text); padding: 1rem;")

      let _ = list_container |> dromel.append_child(empty_msg)
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
          dromel.new_div()
          |> dromel.set_style(
            "padding: 0.5rem; cursor: pointer; background: "
            <> bg_color
            <> "; color: var(--color-body-text); border-radius: 4px; margin-bottom: 0.25rem;",
          )

        // Contract row: icon + name + kind
        let name_container =
          dromel.new_div()
          |> dromel.set_style(
            "display: flex; align-items: center; gap: 0.5rem;",
          )

        // Add icon based on contract kind
        let icon_svg = case contract {
          audit_data.NamedTopic(
            kind: audit_data.TopicContract(audit_data.Contract),
            ..,
          ) -> icons.file_braces
          audit_data.NamedTopic(
            kind: audit_data.TopicContract(audit_data.Interface),
            ..,
          ) -> icons.file_sliders
          audit_data.NamedTopic(
            kind: audit_data.TopicContract(audit_data.Library),
            ..,
          ) -> icons.file_exclamation
          audit_data.NamedTopic(
            kind: audit_data.TopicContract(audit_data.Abstract),
            ..,
          ) -> icons.file_question
          _ -> icons.file_braces
        }

        let icon_container =
          dromel.new_span()
          |> dromel.set_style(
            "display: flex; align-items: center; flex-shrink: 0;",
          )
          |> dromel.set_inner_html(icon_svg)

        // Get name from metadata and highlight matching search term
        let contract_name = audit_data.topic_metadata_name(contract)
        let highlighted_name =
          search.highlight_match(contract_name, search_query)

        let name_span =
          dromel.new_span()
          |> dromel.set_inner_html(highlighted_name)

        let kind_label = case contract {
          audit_data.NamedTopic(kind: audit_data.TopicContract(kind), ..) ->
            audit_data.contract_kind_to_string(kind)
          _ -> ""
        }

        let kind_span =
          dromel.new_span()
          |> dromel.set_inner_text(kind_label)
          |> dromel.set_style("font-size: 0.85rem; opacity: 0.7;")

        let _ = name_container |> dromel.append_child(icon_container)
        let _ = name_container |> dromel.append_child(name_span)
        let _ = name_container |> dromel.append_child(kind_span)
        let _ = item |> dromel.append_child(name_container)
        let _ = list_container |> dromel.append_child(item)

        item
      })
      |> list.each(fn(_) { Nil })

      Nil
    }
  }
}

fn render_preview(preview_pane: element.Element, html: String) -> Nil {
  let _ = preview_pane |> dromel.set_inner_html(html)
  Nil
}

fn render_preview_error(preview_pane: element.Element, error: String) -> Nil {
  render_preview(preview_pane, "Error loading preview:<br><br>" <> error)
}

// ============================================================================
// Preview Loading with Race Condition Protection
// ============================================================================

fn load_preview(topic: audit_data.Topic) -> Nil {
  // Update state to track current preview
  case get_contracts_modal_state() {
    Ok(state) -> {
      set_contracts_modal_state(
        ContractsModalState(..state, current_preview_topic_id: Some(topic.id)),
      )

      // Show loading indicator
      render_preview(state.right_pane, "Loading preview...")

      // Fetch source text
      audit_data.with_source_text(topic, fn(result) {
        // Check if this is still the current selection
        case get_contracts_modal_state() {
          Ok(current_state) -> {
            case current_state.current_preview_topic_id {
              Some(current_topic_id) if current_topic_id == topic.id -> {
                // Still current, render it
                case result {
                  Ok(text) -> render_preview(current_state.right_pane, text)
                  Error(err) ->
                    render_preview_error(
                      current_state.right_pane,
                      snag.line_print(err),
                    )
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
    search.filter(state.all_contracts, query, audit_data.topic_metadata_name)

  // Update state with new query
  set_contracts_modal_state(
    ContractsModalState(
      ..state,
      filtered_contracts: filtered,
      selected_index: 0,
      search_query: query,
    ),
  )

  // Re-render list with search highlighting
  render_contract_list(state.left_pane, filtered, 0, query)

  // Load preview for first item if any
  case list.first(filtered) {
    Ok(contract) -> load_preview(contract.topic)
    Error(_) -> Nil
  }
}

fn handle_keydown(
  e: event.Event(event.UIEvent(event.KeyboardEvent)),
  state: ContractsModalState,
  overlay: element.Element,
) -> Nil {
  let list_length = list.length(state.filtered_contracts)

  case event.key(e) {
    "Escape" -> {
      event.prevent_default(e)
      modal.close_modal(overlay)
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

      render_contract_list(
        state.left_pane,
        state.filtered_contracts,
        new_index,
        state.search_query,
      )

      case get_at(state.filtered_contracts, new_index) {
        Ok(contract) -> load_preview(contract.topic)
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

      render_contract_list(
        state.left_pane,
        state.filtered_contracts,
        new_index,
        state.search_query,
      )

      case get_at(state.filtered_contracts, new_index) {
        Ok(contract) -> load_preview(contract.topic)
        Error(_) -> Nil
      }
    }

    "Enter" if list_length > 0 -> {
      event.prevent_default(e)

      // Get the selected contract and navigate to its topic view
      case get_at(state.filtered_contracts, state.selected_index) {
        Ok(contract) -> {
          let container = audit_data.topic_view_container()

          // Navigate to the entry (creates and displays the view)
          topic_view.navigate_to_new_entry(container, contract.topic)

          // Close the modal after successfully navigating
          modal.close_modal(overlay)
        }
        Error(Nil) -> {
          io.println_error("No contract selected in contracts modal")
        }
      }
    }

    _ -> Nil
  }
}

// ============================================================================
// Public API
// ============================================================================

pub fn open() -> Nil {
  // Mount the modal (creates DOM and initializes state)
  let modal_elements = modal.open_modal(mount_contracts_modal)

  // Add keyboard handler with overlay reference
  let _ =
    modal_elements.overlay
    |> dromel.add_event_listener("keydown", fn(e) {
      case get_contracts_modal_state() {
        Ok(state) -> handle_keydown(e, state, modal_elements.overlay)
        Error(_) -> Nil
      }
    })

  // Focus the search input
  case dromel.query_document(elements.modal_search_input_class) {
    Ok(input) -> {
      let _ = input |> dromel.focus()
      Nil
    }
    Error(_) -> Nil
  }

  // Fetch contracts and initialize
  audit_data.with_audit_contracts(fn(result) { on_contracts_loaded(result) })
}

fn on_contracts_loaded(
  result: Result(List(audit_data.TopicMetadata), snag.Snag),
) -> Nil {
  case get_contracts_modal_state() {
    Ok(state) -> {
      case result {
        Error(err) -> {
          // Display error in list pane
          let _ =
            state.left_pane
            |> dromel.set_inner_html(
              "<div style='color: var(--color-body-text); padding: 1rem;'>Error loading contracts:<br><br>"
              <> snag.line_print(err)
              <> "</div>",
            )

          // Show error in preview pane
          render_preview_error(state.right_pane, snag.line_print(err))
        }

        Ok(contracts) -> {
          case list.is_empty(contracts) {
            True -> {
              // Treat empty list as error
              let _ =
                state.left_pane
                |> dromel.set_inner_html(
                  "<div style='color: var(--color-body-text); padding: 1rem;'>No contracts found</div>",
                )
              render_preview_error(state.right_pane, "No contracts available")
            }

            False -> {
              // Update modal state with contracts, keeping element references
              set_contracts_modal_state(ContractsModalState(
                all_contracts: contracts,
                filtered_contracts: contracts,
                selected_index: 0,
                current_preview_topic_id: None,
                search_query: "",
                left_pane: state.left_pane,
                right_pane: state.right_pane,
              ))

              // Render contract list (no search query initially)
              render_contract_list(state.left_pane, contracts, 0, "")

              // Load preview for first contract
              case list.first(contracts) {
                Ok(contract) -> load_preview(contract.topic)
                Error(_) -> Nil
              }
            }
          }
        }
      }
    }
    Error(_) -> Nil
  }
}
