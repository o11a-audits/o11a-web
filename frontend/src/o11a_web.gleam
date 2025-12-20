import audit_data
import elements
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import plinth/browser/document
import plinth/browser/element
import plinth/browser/event
import plinth/browser/window
import snag

pub fn main() {
  let assert Ok(audit_name) = extract_audit_name()
  audit_data.set_audit_name(audit_name)
  io.println("Hello from o11a_web at " <> audit_name)

  let _ = populate_audit_name_tag(audit_name)

  audit_data.with_audit_contracts(audit_name, fn(contracts) {
    case contracts {
      Error(snag) -> {
        echo snag.line_print(snag) as "contracts: "
        Nil
      }
      Ok(contracts) -> {
        echo contracts as "contracts: "

        // Fetch source text for each contract's topic
        contracts
        |> list.each(fn(contract) {
          audit_data.with_source_text(
            audit_name,
            contract.topic,
            fn(source_text) {
              case source_text {
                Error(snag) -> {
                  echo snag.line_print(snag) as "source_text error: "
                  Nil
                }
                Ok(text) -> {
                  let _ =
                    echo text as "source_text for " <> contract.topic.id <> ": "
                  Nil
                }
              }
            },
          )
        })

        Nil
      }
    }
  })

  window.add_event_listener("keydown", fn(event) {
    // Only handle global shortcuts when not in input context
    case is_in_input_context() {
      True -> Nil
      False -> {
        case event.key(event) {
          "t" -> {
            event.prevent_default(event)
            event.stop_propagation(event)
            open_modal(audit_name)
          }
          _ -> Nil
        }
      }
    }
  })

  Ok(Nil)
}

pub fn populate_audit_name_tag(audit_name) {
  use header <- result.try(document.query_selector(
    elements.dynamic_header.selector,
  ))

  let audit_name_tag = document.create_element("span")
  element.set_inner_text(audit_name_tag, audit_name)
  element.set_attribute(audit_name_tag, "style", "margin-right: 0.5rem")

  element.append_child(header, audit_name_tag)

  Ok(Nil)
}

// Extract audit name from pathname
// For a path like "/my-audit", this returns "my-audit"
pub fn extract_audit_name() {
  case window.pathname() |> echo |> string.split("/") |> echo {
    ["", audit_name, ..] -> Ok(audit_name)
    _ -> Error(Nil)
  }
}

// ============================================================================
// Modal State Management
// ============================================================================

pub type ModalState {
  ModalState(
    all_contracts: List(audit_data.Contract),
    filtered_contracts: List(audit_data.Contract),
    selected_index: Int,
    current_preview_topic_id: Option(String),
  )
}

@external(javascript, "./mem_ffi.mjs", "init_modal_state")
fn init_modal_state() -> Nil

@external(javascript, "./mem_ffi.mjs", "get_modal_state")
fn get_modal_state() -> Result(ModalState, Nil)

@external(javascript, "./mem_ffi.mjs", "set_modal_state")
fn set_modal_state(state: ModalState) -> Nil

@external(javascript, "./mem_ffi.mjs", "clear_modal_state")
fn clear_modal_state() -> Nil

@external(javascript, "./mem_ffi.mjs", "set_input_context")
fn set_input_context() -> Nil

@external(javascript, "./mem_ffi.mjs", "clear_input_context")
fn clear_input_context() -> Nil

@external(javascript, "./mem_ffi.mjs", "is_in_input_context")
fn is_in_input_context() -> Bool

// ============================================================================
// Helper Functions
// ============================================================================

fn get_at(list: List(a), index: Int) -> Result(a, Nil) {
  list
  |> list.drop(index)
  |> list.first
}

// Highlight the first occurrence of search query in text (case-insensitive)
fn highlight_match(text: String, query: String) -> String {
  case string.trim(query) {
    "" -> text
    q -> {
      let lower_text = string.lowercase(text)
      let lower_query = string.lowercase(q)

      case string.split_once(lower_text, lower_query) {
        Ok(#(before_lower, _after_lower)) -> {
          // Calculate positions in original text
          let before_len = string.length(before_lower)
          let query_len = string.length(q)

          // Extract parts from original text preserving case
          let before = string.slice(text, 0, before_len)
          let matched = string.slice(text, before_len, query_len)
          let after =
            string.slice(text, before_len + query_len, string.length(text))

          before
          <> "<span style='color: var(--color-brand-purple);'>"
          <> matched
          <> "</span>"
          <> after
        }
        Error(_) -> text
      }
    }
  }
}

// ============================================================================
// Filter Contracts
// ============================================================================

fn filter_contracts(
  contracts: List(audit_data.Contract),
  query: String,
) -> List(audit_data.Contract) {
  case string.trim(query) {
    "" -> contracts
    q -> {
      let lower_query = string.lowercase(q)
      list.filter(contracts, fn(contract) {
        string.lowercase(contract.name)
        |> string.contains(lower_query)
      })
    }
  }
}

// ============================================================================
// Rendering Functions
// ============================================================================

fn render_contract_list(
  contracts: List(audit_data.Contract),
  selected_index: Int,
  search_query: String,
) -> Nil {
  case document.query_selector(".contract-list") {
    Ok(list_container) -> {
      // Clear existing content
      element.set_inner_html(list_container, "")

      case list.is_empty(contracts) {
        True -> {
          let empty_msg = document.create_element("div")
          element.set_inner_text(empty_msg, "No contracts match filter")
          element.set_attribute(
            empty_msg,
            "style",
            "color: var(--color-body-text); padding: 1rem;",
          )
          element.append_child(list_container, empty_msg)
          Nil
        }
        False -> {
          // Render each contract
          contracts
          |> list.index_map(fn(contract, idx) {
            let item = document.create_element("div")
            element.set_attribute(item, "data-index", int.to_string(idx))

            let is_selected = idx == selected_index
            let bg_color = case is_selected {
              True -> "var(--color-code-selection-bg)"
              False -> "transparent"
            }

            element.set_attribute(
              item,
              "style",
              "padding: 0.5rem; cursor: pointer; background: "
                <> bg_color
                <> "; color: var(--color-body-text); border-radius: 4px; margin-bottom: 0.25rem;",
            )

            // Contract name and kind on same line
            let name_container = document.create_element("div")
            element.set_attribute(
              name_container,
              "style",
              "display: flex; justify-content: space-between; align-items: center;",
            )

            let name_span = document.create_element("span")
            // Highlight matching search term in contract name
            let highlighted_name = highlight_match(contract.name, search_query)
            element.set_inner_html(name_span, highlighted_name)

            let kind_span = document.create_element("span")
            element.set_inner_text(kind_span, contract.kind)
            element.set_attribute(
              kind_span,
              "style",
              "font-size: 0.85rem; opacity: 0.7;",
            )

            element.append_child(name_container, name_span)
            element.append_child(name_container, kind_span)
            element.append_child(item, name_container)
            element.append_child(list_container, item)

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
  case document.query_selector("#preview-content") {
    Ok(preview) -> {
      element.set_inner_html(preview, html)
      Nil
    }
    Error(_) -> Nil
  }
}

fn render_preview_error(error: String) -> Nil {
  case document.query_selector("#preview-content") {
    Ok(preview) -> {
      element.set_inner_html(preview, "Error loading preview:<br><br>" <> error)
      Nil
    }
    Error(_) -> Nil
  }
}

// ============================================================================
// Preview Loading with Race Condition Protection
// ============================================================================

fn load_preview(audit_name: String, topic: audit_data.Topic) -> Nil {
  // Update state to track current preview
  case get_modal_state() {
    Ok(state) -> {
      set_modal_state(
        ModalState(..state, current_preview_topic_id: Some(topic.id)),
      )

      // Show loading indicator
      render_preview("Loading preview...")

      // Fetch source text
      audit_data.with_source_text(audit_name, topic, fn(result) {
        // Check if this is still the current selection
        case get_modal_state() {
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

fn handle_search_input(_event: event.Event(t)) -> Nil {
  case document.query_selector("#contract-search") {
    Ok(input) -> {
      case element.value(input) {
        Ok(query) -> {
          case get_modal_state() {
            Ok(state) -> {
              let filtered = filter_contracts(state.all_contracts, query)

              // Update state
              set_modal_state(
                ModalState(
                  ..state,
                  filtered_contracts: filtered,
                  selected_index: 0,
                ),
              )

              // Re-render list with search highlighting
              render_contract_list(filtered, 0, query)

              // Load preview for first item if any
              case list.first(filtered) {
                Ok(contract) -> {
                  let assert Ok(audit_name) = extract_audit_name()
                  load_preview(audit_name, contract.topic)
                }
                Error(_) -> Nil
              }
            }
            Error(_) -> Nil
          }
        }
        Error(_) -> Nil
      }
    }
    Error(_) -> Nil
  }
}

fn handle_modal_keydown(
  e: event.Event(event.UIEvent(event.KeyboardEvent)),
  audit_name: String,
) -> Nil {
  case get_modal_state() {
    Ok(state) -> {
      let list_length = list.length(state.filtered_contracts)

      case event.key(e) {
        "Escape" -> {
          event.prevent_default(e)
          close_modal()
        }

        "ArrowDown" if list_length > 0 -> {
          event.prevent_default(e)
          let new_index = case state.selected_index + 1 >= list_length {
            True -> 0
            False -> state.selected_index + 1
          }

          set_modal_state(ModalState(..state, selected_index: new_index))

          // Get current search query for highlighting
          let search_query = case document.query_selector("#contract-search") {
            Ok(input) ->
              case element.value(input) {
                Ok(q) -> q
                Error(_) -> ""
              }
            Error(_) -> ""
          }
          render_contract_list(
            state.filtered_contracts,
            new_index,
            search_query,
          )

          case get_at(state.filtered_contracts, new_index) {
            Ok(contract) -> load_preview(audit_name, contract.topic)
            Error(_) -> Nil
          }
        }

        "ArrowUp" if list_length > 0 -> {
          event.prevent_default(e)
          let new_index = case state.selected_index - 1 < 0 {
            True -> list_length - 1
            False -> state.selected_index - 1
          }

          set_modal_state(ModalState(..state, selected_index: new_index))

          // Get current search query for highlighting
          let search_query = case document.query_selector("#contract-search") {
            Ok(input) ->
              case element.value(input) {
                Ok(q) -> q
                Error(_) -> ""
              }
            Error(_) -> ""
          }
          render_contract_list(
            state.filtered_contracts,
            new_index,
            search_query,
          )

          case get_at(state.filtered_contracts, new_index) {
            Ok(contract) -> load_preview(audit_name, contract.topic)
            Error(_) -> Nil
          }
        }

        "Enter" if list_length > 0 -> {
          event.prevent_default(e)
          // Future: navigate to contract
          close_modal()
        }

        _ -> Nil
      }
    }
    Error(_) -> Nil
  }
}

// ============================================================================
// DOM Creation
// ============================================================================

fn create_modal_dom(audit_name: String) -> element.Element {
  // Overlay (full screen backdrop)
  let modal = document.create_element("div")
  element.set_attribute(modal, "id", "contracts-modal")
  element.set_attribute(
    modal,
    "style",
    "position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.8); z-index: 1000; display: flex; align-items: center; justify-content: center;",
  )

  // Container - sized to fit content
  let container = document.create_element("div")
  element.set_attribute(
    container,
    "style",
    "height: 60ch; background: var(--color-body-bg); border: 1px solid var(--color-body-border); display: flex; flex-direction: row; border-radius: 4px;",
  )

  // Left column (40ch content width + padding)
  let left_column = document.create_element("div")
  element.set_attribute(
    left_column,
    "style",
    "display: flex; flex-direction: column; border-right: 1px solid var(--color-body-border);",
  )

  // Search input container (only on left)
  let search_container = document.create_element("div")
  element.set_attribute(
    search_container,
    "style",
    "padding: 0.5rem; border-bottom: 1px solid var(--color-body-border);",
  )

  let search_input = document.create_element("input")
  element.set_attribute(search_input, "type", "text")
  element.set_attribute(search_input, "id", "contract-search")
  element.set_attribute(search_input, "placeholder", "Search contracts...")
  element.set_attribute(
    search_input,
    "style",
    "width: 100%; padding: 0.5rem; background: var(--color-code-bg); color: var(--color-body-text); border: 1px solid var(--color-body-border); border-radius: 4px; font-size: 14px; box-sizing: border-box;",
  )

  element.append_child(search_container, search_input)

  // Contract list pane (left, 40ch content width)
  let list_pane = document.create_element("div")
  element.set_attribute(list_pane, "class", "contract-list")
  element.set_attribute(
    list_pane,
    "style",
    "width: 40ch; overflow-y: auto; background: var(--color-code-bg); padding: 0.5rem; flex: 1;",
  )

  element.append_child(left_column, search_container)
  element.append_child(left_column, list_pane)

  // Preview pane (right, 40ch content width)
  let preview_pane = document.create_element("div")
  element.set_attribute(
    preview_pane,
    "style",
    "width: 40ch; overflow-y: auto; background: var(--color-code-bg); padding: 1rem;",
  )

  let preview_content = document.create_element("div")
  element.set_attribute(preview_content, "id", "preview-content")
  element.set_attribute(
    preview_content,
    "style",
    "margin: 0; color: var(--color-code-text);",
  )
  element.set_inner_html(preview_content, "Loading...")

  element.append_child(preview_pane, preview_content)
  element.append_child(container, left_column)
  element.append_child(container, preview_pane)
  element.append_child(modal, container)

  // Attach event listeners
  let _search_cleanup =
    element.add_event_listener(search_input, "input", handle_search_input)

  // Track focus context to prevent global shortcuts while typing
  let _input_focus_cleanup =
    element.add_event_listener(search_input, "focus", fn(_e) {
      set_input_context()
    })

  let _input_blur_cleanup =
    element.add_event_listener(search_input, "blur", fn(_e) {
      clear_input_context()
    })

  let _keydown_cleanup =
    element.add_event_listener(modal, "keydown", fn(e) {
      handle_modal_keydown(e, audit_name)
    })

  // Click on overlay to close
  let _click_cleanup =
    element.add_event_listener(modal, "click", fn(e) {
      case event.target(e) {
        target -> {
          case element.cast(target) {
            Ok(elem) -> {
              case element.get_attribute(elem, "id") {
                Ok("contracts-modal") -> close_modal()
                _ -> Nil
              }
            }
            Error(_) -> Nil
          }
        }
      }
    })

  modal
}

// ============================================================================
// Modal Lifecycle
// ============================================================================

fn open_modal(audit_name: String) -> Nil {
  // Check if modal is already open
  case document.query_selector("#contracts-modal") {
    Ok(_existing_modal) -> {
      // Modal already open, just focus the search input
      case document.query_selector("#contract-search") {
        Ok(input) -> {
          element.focus(input)
          Nil
        }
        Error(_) -> Nil
      }
    }
    Error(_) -> {
      // Modal not open, create it
      // Initialize modal state
      init_modal_state()

      // Create modal DOM
      let modal = create_modal_dom(audit_name)

      // Append to #app div
      case document.query_selector("#app") {
        Ok(app_div) -> {
          element.append_child(app_div, modal)

          // Fetch contracts
          audit_data.with_audit_contracts(audit_name, on_contracts_loaded)

          // Focus search input after a brief delay
          case document.query_selector("#contract-search") {
            Ok(input) -> {
              element.focus(input)
              Nil
            }
            Error(_) -> Nil
          }
        }
        Error(_) -> Nil
      }
    }
  }
}

fn on_contracts_loaded(
  result: Result(List(audit_data.Contract), snag.Snag),
) -> Nil {
  case result {
    Error(err) -> {
      // Display error in list pane
      case document.query_selector(".contract-list") {
        Ok(list_container) -> {
          element.set_inner_html(
            list_container,
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
          case document.query_selector(".contract-list") {
            Ok(list_container) -> {
              element.set_inner_html(
                list_container,
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
          set_modal_state(ModalState(
            all_contracts: contracts,
            filtered_contracts: contracts,
            selected_index: 0,
            current_preview_topic_id: None,
          ))

          // Render contract list (no search query initially)
          render_contract_list(contracts, 0, "")

          // Load preview for first contract
          case list.first(contracts) {
            Ok(contract) -> {
              let assert Ok(audit_name) = extract_audit_name()
              load_preview(audit_name, contract.topic)
            }
            Error(_) -> Nil
          }
        }
      }
    }
  }
}

fn close_modal() -> Nil {
  case document.query_selector("#contracts-modal") {
    Ok(modal) -> {
      element.remove(modal)
      clear_modal_state()
      clear_input_context()
      Nil
    }
    Error(_) -> Nil
  }
}
