import audit_data
import context
import core/log
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
// Documents Modal State
// ============================================================================

pub type DocumentsModalState {
  DocumentsModalState(
    all_documents: List(audit_data.TopicMetadata),
    filtered_documents: List(audit_data.TopicMetadata),
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

@external(javascript, "../mem_ffi.mjs", "get_documents_modal_state")
fn get_documents_modal_state() -> Result(DocumentsModalState, Nil)

@external(javascript, "../mem_ffi.mjs", "set_documents_modal_state")
fn set_documents_modal_state(state: DocumentsModalState) -> Nil

fn init_documents_modal_state(
  left_pane: element.Element,
  right_pane: element.Element,
) -> Nil {
  set_documents_modal_state(DocumentsModalState(
    all_documents: [],
    filtered_documents: [],
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

fn mount_documents_modal(container: element.Element) -> Nil {
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
    |> dromel.set_placeholder("Search documents...")
    |> dromel.set_style(
      "width: 100%; padding: 0.5rem; background: var(--color-body-bg); color: var(--color-body-text); border: none; font-size: 14px; box-sizing: border-box;",
    )
    |> dromel.add_event_listener("input", fn(e) {
      case get_documents_modal_state() {
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
    |> dromel.add_event_listener("focus", fn(_e) {
      context.add_context(context.Input)
    })
    |> dromel.add_event_listener("blur", fn(_e) {
      context.remove_context(context.Input)
    })

  let _ = search_container |> dromel.append_child(search_input)

  // Left pane (document list)
  let left_pane =
    dromel.new_div()
    |> dromel.set_class(elements.modal_left_pane_class)
    |> dromel.add_class(elements.source_container_class)
    |> dromel.set_style(
      "background: var(--color-body-bg); padding: 0.5rem; flex: 1;",
    )
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text); padding: 1rem;'>Loading documents...</div>",
    )

  let _ = left_column |> dromel.append_child(search_container)
  let _ = left_column |> dromel.append_child(left_pane)

  // Right pane (preview)
  let right_pane =
    dromel.new_div()
    |> dromel.set_class(elements.modal_right_pane_class)
    |> dromel.add_class(elements.source_container_class)
    |> dromel.set_style("background: var(--color-code-bg); padding: 1rem;")
    |> dromel.set_inner_html("Loading...")

  let _ = container |> dromel.append_child(left_column)
  let _ = container |> dromel.append_child(right_pane)

  // Initialize state with element references
  init_documents_modal_state(left_pane, right_pane)
}

// ============================================================================
// Rendering Functions
// ============================================================================

fn get_document_name(document: audit_data.TopicMetadata) -> String {
  case document {
    audit_data.NamedTopic(name:, ..) | audit_data.NamedMutableTopic(name:, ..) ->
      name
    audit_data.UnnamedTopic(scope:, ..) ->
      case scope {
        audit_data.Container(container:) -> container
        _ -> audit_data.topic_metadata_name(document)
      }
  }
}

fn render_document_list(
  list_container: element.Element,
  documents: List(audit_data.TopicMetadata),
  selected_index: Int,
  search_query: String,
) -> Nil {
  // Clear existing content
  let _ = list_container |> dromel.set_inner_html("")

  case list.is_empty(documents) {
    True -> {
      let empty_msg =
        dromel.new_div()
        |> dromel.set_inner_text("No documents match filter")
        |> dromel.set_style("color: var(--color-body-text); padding: 1rem;")

      let _ = list_container |> dromel.append_child(empty_msg)
      Nil
    }
    False -> {
      // Render each document
      documents
      |> list.index_map(fn(document, idx) {
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

        // Document row: icon + name
        let name_container =
          dromel.new_div()
          |> dromel.set_style(
            "display: flex; align-items: center; gap: 0.5rem;",
          )

        // Use a document icon
        let icon_container =
          dromel.new_span()
          |> dromel.set_style(
            "display: flex; align-items: center; flex-shrink: 0;",
          )
          |> dromel.set_inner_html(icons.file_text)

        // Get name from metadata and highlight matching search term
        let document_name = get_document_name(document)
        let highlighted_name =
          search.highlight_match(document_name, search_query)

        let name_span =
          dromel.new_span()
          |> dromel.set_inner_html(highlighted_name)

        let _ = name_container |> dromel.append_child(icon_container)
        let _ = name_container |> dromel.append_child(name_span)
        let _ = item |> dromel.append_child(name_container)
        let _ = list_container |> dromel.append_child(item)

        item
      })
      |> list.each(fn(_) { Nil })

      Nil
    }
  }
}

// ============================================================================
// Preview Loading with Race Condition Protection
// ============================================================================

fn get_document_topic(document: audit_data.TopicMetadata) -> audit_data.Topic {
  case document {
    audit_data.NamedTopic(topic:, ..)
    | audit_data.NamedMutableTopic(topic:, ..)
    | audit_data.UnnamedTopic(topic:, ..) -> topic
  }
}

fn load_preview(topic: audit_data.Topic) -> Nil {
  // Update state to track current preview
  case get_documents_modal_state() {
    Ok(state) -> {
      set_documents_modal_state(
        DocumentsModalState(..state, current_preview_topic_id: Some(topic.id)),
      )

      // Show loading indicator
      dromel.set_inner_html(state.right_pane, "Loading preview...")

      // Fetch source text
      audit_data.with_source_text(topic, fn(result) {
        // Check if this is still the current selection
        case get_documents_modal_state() {
          Ok(current_state) -> {
            case current_state.current_preview_topic_id {
              Some(current_topic_id) if current_topic_id == topic.id -> {
                // Still current, render it
                case result {
                  Ok(text) -> {
                    dromel.set_inner_html(current_state.right_pane, text)
                    Nil
                  }
                  Error(error) -> {
                    dromel.set_inner_html(
                      current_state.right_pane,
                      log.render_source_error(error),
                    )
                    Nil
                  }
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

fn handle_search_input(query: String, state: DocumentsModalState) -> Nil {
  let filtered = search.filter(state.all_documents, query, get_document_name)

  // Update state with new query
  set_documents_modal_state(
    DocumentsModalState(
      ..state,
      filtered_documents: filtered,
      selected_index: 0,
      search_query: query,
    ),
  )

  // Re-render list with search highlighting
  render_document_list(state.left_pane, filtered, 0, query)

  // Load preview for first item if any
  case list.first(filtered) {
    Ok(document) -> load_preview(get_document_topic(document))
    Error(_) -> Nil
  }
}

fn handle_keydown(
  e: event.Event(event.UIEvent(event.KeyboardEvent)),
  overlay: element.Element,
) -> Nil {
  let state = case get_documents_modal_state() {
    Ok(state) -> state
    Error(_) -> panic as "no modal state"
  }
  let list_length = list.length(state.filtered_documents)

  case event.key(e) {
    "Escape" -> {
      event.prevent_default(e)
      modal.close_modal(overlay)
      context.remove_context(context.DocumentsModal)
    }

    "ArrowDown" if list_length > 0 -> {
      event.prevent_default(e)
      let new_index = case state.selected_index + 1 >= list_length {
        True -> 0
        False -> state.selected_index + 1
      }

      set_documents_modal_state(
        DocumentsModalState(..state, selected_index: new_index),
      )

      render_document_list(
        state.left_pane,
        state.filtered_documents,
        new_index,
        state.search_query,
      )

      case get_at(state.filtered_documents, new_index) {
        Ok(document) -> load_preview(get_document_topic(document))
        Error(_) -> Nil
      }
    }

    "ArrowUp" if list_length > 0 -> {
      event.prevent_default(e)
      let new_index = case state.selected_index - 1 < 0 {
        True -> list_length - 1
        False -> state.selected_index - 1
      }

      set_documents_modal_state(
        DocumentsModalState(..state, selected_index: new_index),
      )

      render_document_list(
        state.left_pane,
        state.filtered_documents,
        new_index,
        state.search_query,
      )

      case get_at(state.filtered_documents, new_index) {
        Ok(document) -> load_preview(get_document_topic(document))
        Error(_) -> Nil
      }
    }

    "Enter" if list_length > 0 -> {
      event.prevent_default(e)

      // Get the selected document and navigate to its topic view
      case get_at(state.filtered_documents, state.selected_index) {
        Ok(document) -> {
          let container = topic_view.topic_view_container()

          // Navigate to the entry (creates and displays the view)
          topic_view.navigate_to_new_entry(
            container,
            get_document_topic(document),
          )

          // Close the modal after successfully navigating
          modal.close_modal(overlay)
          context.remove_context(context.DocumentsModal)
        }
        Error(Nil) -> {
          io.println_error("No document selected in documents modal")
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
  let modal_elements = modal.open_modal(mount_documents_modal)

  // Add keyboard handler with overlay reference
  let _ =
    modal_elements.overlay
    |> dromel.add_event_listener("keydown", fn(e) {
      handle_keydown(e, modal_elements.overlay)
    })

  // Focus the search input
  case dromel.query_document(elements.modal_search_input_class) {
    Ok(input) -> {
      let _ = input |> dromel.focus()
      Nil
    }
    Error(_) -> Nil
  }

  // Fetch documents and initialize
  audit_data.with_audit_documents(fn(result) { on_documents_loaded(result) })

  context.add_context(context.DocumentsModal)
}

fn on_documents_loaded(
  result: Result(List(audit_data.TopicMetadata), snag.Snag),
) -> Nil {
  case get_documents_modal_state() {
    Ok(state) -> {
      case result {
        Error(error) -> {
          // Display error in list pane
          dromel.set_inner_html(state.left_pane, log.render_source_error(error))

          // Show nothing in preview pane
          dromel.set_inner_html(state.right_pane, "")
          Nil
        }

        Ok(documents) -> {
          case list.is_empty(documents) {
            True -> {
              // Treat empty list as error
              dromel.set_inner_html(
                state.left_pane,
                log.render_source_error(snag.new("No documents found")),
              )

              // Show nothing in preview pane
              dromel.set_inner_html(state.right_pane, "")
              Nil
            }

            False -> {
              // Update modal state with documents, keeping element references
              set_documents_modal_state(DocumentsModalState(
                all_documents: documents,
                filtered_documents: documents,
                selected_index: 0,
                current_preview_topic_id: None,
                search_query: "",
                left_pane: state.left_pane,
                right_pane: state.right_pane,
              ))

              // Render document list (no search query initially)
              render_document_list(state.left_pane, documents, 0, "")

              // Load preview for first document
              case list.first(documents) {
                Ok(document) -> load_preview(get_document_topic(document))
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
