//// Topic View Module
////
//// This module manages the display of source text views with navigation history support.
//// Multiple views can exist in the DOM simultaneously, but only one is visible at a time.
//// Each view is associated with a navigation history entry that tracks forward/back navigation.
////
//// ## Basic Usage
////
//// ```gleam
//// // 1. Create a container element for views
//// let view_container = dromel.new_div()
////   |> dromel.set_style("width: 100%; height: 100%;")
////
//// let _ = audit_data.app_element() |> dromel.append_child(view_container)
////
//// // 2. Create a root navigation entry
//// let root_entry_id = history_graph.create_root(
////   topic_id: "contract-123",
////   name: "MyContract"
//// )
////
//// // 3. Navigate to the entry (creates and displays the view)
//// case topic_view.navigate_to_entry(view_container, root_entry_id) {
////   Ok(_) -> io.println("View displayed")
////   Error(err) -> io.println("Error: " <> snag.line_print(err))
//// }
////
//// // 4. Navigate to a child topic
//// case topic_view.get_active_entry_id() {
////   Ok(current_entry_id) -> {
////     // Get current scroll position or line number
////     let line_number = 42
////
////     // Create child entry
////     case history_graph.navigate_to(
////       current_entry_id,
////       line_number,
////       new_topic_id: "function-456",
////       new_name: "myFunction"
////     ) {
////       Ok(new_entry_id) -> {
////         // Display the new view
////         topic_view.navigate_to_entry(view_container, new_entry_id)
////       }
////       Error(err) -> Error(err)
////     }
////   }
////   Error(err) -> Error(err)
//// }
////
//// // 5. Navigate back/forward
//// topic_view.go_back()  // Returns to parent view
//// topic_view.go_forward()  // Goes to most recent child view
//// ```
////
//// ## Navigation Example
////
//// ```gleam
//// // Add keyboard navigation
//// window.add_event_listener("keydown", fn(event) {
////   case event.key(event) {
////     "h" if topic_view.can_navigate_back() -> {
////       event.prevent_default(event)
////       case topic_view.go_back() {
////         Ok(_) -> Nil
////         Error(_) -> Nil
////       }
////     }
////     "l" if topic_view.can_navigate_forward() -> {
////       event.prevent_default(event)
////       case topic_view.go_forward() {
////         Ok(_) -> Nil
////         Error(_) -> Nil
////       }
////     }
////     _ -> Nil
////   }
//// })
//// ```

import audit_data
import dromel
import gleam/int
import gleam/io
import gleam/javascript/array
import gleam/list
import gleam/result
import history_graph
import plinth/browser/element
import plinth/browser/event
import snag
import ui/elements

// ============================================================================
// Topic View State
// ============================================================================

pub type TopicView {
  TopicView(
    entry_id: String,
    topic_id: String,
    topic_panel: element.Element,
    topic_container: element.Element,
    references_panel: element.Element,
    references_container: element.Element,
    topic_children_tokens: array.Array(element.Element),
  )
}

// ============================================================================
// FFI Bindings for State Management
// ============================================================================

@external(javascript, "../mem_ffi.mjs", "set_history_container")
pub fn set_history_container(container: element.Element) -> Nil

@external(javascript, "../mem_ffi.mjs", "get_history_container")
fn get_history_container_ffi() -> Result(element.Element, Nil)

@external(javascript, "../mem_ffi.mjs", "replace_url")
fn replace_url(url: String) -> Nil

fn get_history_container() {
  let assert Ok(container) = get_history_container_ffi()
  container
}

fn update_url_for_topic(topic_id: String) -> Nil {
  replace_url("/" <> audit_data.audit_name() <> "/" <> topic_id)
}

@external(javascript, "../mem_ffi.mjs", "set_topic_view_container")
pub fn set_topic_view_container(element: dromel.Element) -> Nil

@external(javascript, "../mem_ffi.mjs", "get_topic_view_container")
fn get_topic_view_container() -> Result(dromel.Element, Nil)

pub fn topic_view_container() -> dromel.Element {
  case get_topic_view_container() {
    Ok(element) -> element
    Error(Nil) -> setup_view_container()
  }
}

const view_container_id = dromel.Id("topic_view_container")

fn setup_view_container() {
  let view_container =
    dromel.new_div()
    |> dromel.set_id(view_container_id)
    |> dromel.set_style(
      "display: flex; flex: 1; min-height: 0; justify-content: center; gap: 0.5rem; background: var(--color-body-bg);",
    )
    |> handle_topic_view_keydown

  let _ = audit_data.app_element() |> dromel.append_child(view_container)

  set_topic_view_container(view_container)

  view_container
}

@external(javascript, "../mem_ffi.mjs", "get_topic_view")
fn get_topic_view(entry_id: String) -> Result(TopicView, Nil)

@external(javascript, "../mem_ffi.mjs", "set_topic_view")
fn set_topic_view(entry_id: String, view: TopicView) -> Nil

const active_topic_view_key = dromel.DataKey("active_topic_view")

fn set_active_topic_view(container: element.Element, view: TopicView) -> Nil {
  let _ = dromel.set_data(container, active_topic_view_key, view.entry_id)
  Nil
}

fn get_active_topic_view(container: element.Element) -> Result(TopicView, Nil) {
  dromel.get_data(container, active_topic_view_key)
  |> result.try(get_topic_view)
}

const current_child_topic_index_key = dromel.DataKey(
  "current_child_topic_index",
)

const topic_key = dromel.DataKey("topic")

fn set_current_child_topic_index(container: element.Element, index: Int) -> Nil {
  let _ =
    dromel.set_data(
      container,
      current_child_topic_index_key,
      int.to_string(index),
    )
  Nil
}

fn get_current_child_topic_index(container: element.Element) -> Int {
  dromel.get_data(container, current_child_topic_index_key)
  |> result.try(int.parse)
  |> result.unwrap(0)
}

// ============================================================================
// View Mounting
// ============================================================================

const panel_style = "border-radius: 8px; border: 1px solid var(--color-body-border); padding: 0.5rem; background: var(--color-code-bg); max-height: 100%;"

fn mount_topic_view(container: element.Element) {
  // Create the source view element
  let topic_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text);'>Loading topic source...</div>",
    )

  let topic_title =
    dromel.new_div()
    |> dromel.set_inner_text("Topic")
    |> dromel.set_style("padding-left: 0.5rem; margin-bottom: 0.5rem;")

  let topic_container =
    dromel.new_div()
    |> dromel.set_style("position: relative; padding-top: 0.5rem;")
    |> dromel.append_child(topic_title)
    |> dromel.append_child(topic_panel)

  // Create the references panel element
  let references_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let references_title =
    dromel.new_div()
    |> dromel.set_inner_text("References")
    |> dromel.set_style("padding-left: 0.5rem; margin-bottom: 0.5rem;")

  let references_container =
    dromel.new_div()
    |> dromel.set_style("position: relative; padding-top: 0.5rem;")
    |> dromel.append_child(references_title)
    |> dromel.append_child(references_panel)

  let _ = container |> dromel.append_child(topic_container)
  let _ = container |> dromel.append_child(references_container)

  #(topic_panel, topic_container, references_panel, references_container)
}

// ============================================================================
// View Visibility Management
// ============================================================================

const hidden_class = dromel.Class("hidden")

fn show_view(view: TopicView) -> Nil {
  let _ = view.topic_container |> dromel.remove_class(hidden_class)
  let _ = view.references_container |> dromel.remove_class(hidden_class)
  Nil
}

fn hide_view(view: TopicView) -> Nil {
  let _ = view.topic_container |> dromel.add_class(hidden_class)
  let _ = view.references_container |> dromel.add_class(hidden_class)
  Nil
}

// ============================================================================
// Public API
// ============================================================================

/// Create or get a view for a navigation entry
/// If the view already exists, it will be reused
/// The view will be made visible and set as the active view
pub fn navigate_to_new_entry(
  container: element.Element,
  topic: audit_data.Topic,
) {
  let active_topic_view_res = get_active_topic_view(container)
  case active_topic_view_res {
    Ok(active_view) if active_view.topic_id == topic.id -> {
      // If the active view is for the same topic, do nothing
      Nil
    }

    _ -> {
      let new_entry = case active_topic_view_res {
        Ok(active_view) -> {
          // If there is an active view, hide it
          hide_view(active_view)

          case
            history_graph.go_to_new_entry(
              active_view.entry_id,
              get_current_child_topic_index(container),
              topic,
            )
          {
            Ok(entry) -> entry
            Error(snag) -> {
              snag.layer(snag, "Unable to navigate to new entry")
              |> snag.line_print
              |> io.println_error
              panic as "Unable to navigate to new entry"
            }
          }
        }
        Error(Nil) -> history_graph.create_root(topic)
      }

      // Create new view
      let #(
        topic_panel,
        topic_container,
        references_panel,
        references_container,
      ) = mount_topic_view(container)

      // Initialize view state
      let view =
        TopicView(
          entry_id: new_entry.id,
          topic_id: new_entry.topic_id,
          topic_panel:,
          topic_container:,
          references_panel:,
          references_container:,
          topic_children_tokens: array.from_list([]),
        )
      set_topic_view(new_entry.id, view)

      // Show the new view
      set_active_topic_view(container, view)
      set_current_child_topic_index(container, 0)
      show_view(view)

      // Update the URL to reflect the active topic
      update_url_for_topic(new_entry.topic_id)

      // Update the breadcrumb
      history_graph.mount_history_breadcrumb(
        get_history_container(),
        new_entry,
        populate_topic_name,
      )

      // Load source text
      audit_data.with_source_text(
        audit_data.Topic(id: new_entry.topic_id),
        fn(result) {
          case result {
            Ok(source_text) -> {
              let _ = view.topic_panel |> dromel.set_inner_html(source_text)

              let children =
                dromel.query_element_all(
                  view.topic_panel,
                  elements.source_topic_tokens,
                )

              set_topic_view(
                new_entry.id,
                TopicView(..view, topic_children_tokens: children),
              )

              let _ = array.get(children, 0) |> result.map(dromel.focus)

              Nil
            }

            Error(error) -> {
              let _ =
                view.topic_panel
                |> dromel.set_inner_html(
                  "<div style='color: var(--color-body-text); padding: 1rem;'>"
                  <> error
                  |> snag.layer("Unable to fetch source")
                  |> snag.pretty_print
                  <> "</div>",
                )

              Nil
            }
          }
        },
      )

      // Load topic metadata and populate references panel
      audit_data.with_topic_metadata(topic, fn(metadata) {
        case metadata {
          Ok(metadata) -> {
            // Populate references panel
            case metadata {
              audit_data.NamedTopic(references: references, ..) -> {
                populate_references_panel(
                  container,
                  references_panel,
                  references,
                )
              }
              audit_data.UnnamedTopic(..) -> {
                let _ =
                  references_panel
                  |> dromel.set_inner_html(
                    "<div style='color: var(--color-body-text); font-size: 0.9rem;'>No references</div>",
                  )
                Nil
              }
            }

            // Set if out of scope
            audit_data.with_in_scope_files(fn(in_scope_files) {
              case list.contains(in_scope_files, metadata.scope.container) {
                True -> Nil
                False -> {
                  dromel.add_style(
                    view.topic_panel,
                    "border-color: var(--color-body-out-of-scope-bg)",
                  )
                  Nil
                }
              }
            })
          }
          Error(_) -> {
            let _ =
              references_panel
              |> dromel.set_inner_html(
                "<div style='color: var(--color-body-text); font-size: 0.9rem;'>Unable to load references</div>",
              )
            Nil
          }
        }
      })
    }
  }
}

/// Navigate back in history
pub fn navigate_back(container) -> Nil {
  case get_active_topic_view(container) {
    Error(Nil) ->
      snag.new("Cannot navigate back, there is no active view")
      |> snag.line_print
      |> io.println_error

    Ok(active_view) -> {
      case history_graph.go_back(active_view.entry_id) {
        Error(snag) ->
          snag.layer(snag, "Cannot navigate back")
          |> snag.line_print
          |> io.println_error

        Ok(#(parent_entry, child_topic_index)) -> {
          case get_topic_view(parent_entry.id) {
            Ok(parent_view) -> {
              // Update the parent entry so that the child that this came from
              // is the first child, and has an updated index
              let other_children =
                parent_entry.children
                |> list.filter(fn(child) { child.id != active_view.entry_id })
              let updated_parent =
                history_graph.HistoryEntry(..parent_entry, children: [
                  history_graph.Relative(
                    active_view.entry_id,
                    get_current_child_topic_index(container),
                  ),
                  ..other_children
                ])
              history_graph.set_history_entry(updated_parent.id, updated_parent)

              hide_view(active_view)

              set_active_topic_view(container, parent_view)
              set_current_child_topic_index(container, child_topic_index)
              show_view(parent_view)

              // Update the URL to reflect the active topic
              update_url_for_topic(parent_entry.topic_id)

              history_graph.mount_history_breadcrumb(
                get_history_container(),
                parent_entry,
                populate_topic_name,
              )

              let _ =
                array.get(parent_view.topic_children_tokens, child_topic_index)
                |> result.map(dromel.focus)

              Nil
            }

            Error(Nil) ->
              snag.new("Cannot navigate back, unable to find prior topic view")
              |> snag.line_print
              |> io.println_error
          }
        }
      }
    }
  }
}

/// Navigate forward in history (to
///  most recent child)
pub fn navigate_forward(container) -> Nil {
  case get_active_topic_view(container) {
    Error(Nil) ->
      snag.new("Cannot navigate Forward, there is no active view")
      |> snag.line_print
      |> io.println_error

    Ok(active_view) -> {
      case history_graph.go_forward(active_view.entry_id) {
        Error(snag) ->
          snag.layer(snag, "Cannot navigate forward")
          |> snag.line_print
          |> io.println_error

        Ok(#(child_entry, child_topic_index)) -> {
          echo "going forward, found" <> int.to_string(child_topic_index)
          case get_topic_view(child_entry.id) {
            Error(Nil) ->
              snag.new("Child view not found for entry: " <> child_entry.id)
              |> snag.line_print
              |> io.println_error

            Ok(child_view) -> {
              hide_view(active_view)

              set_active_topic_view(container, child_view)
              set_current_child_topic_index(container, child_topic_index)
              show_view(child_view)

              // Update the URL to reflect the active topic
              update_url_for_topic(child_entry.topic_id)

              history_graph.mount_history_breadcrumb(
                get_history_container(),
                child_entry,
                populate_topic_name,
              )

              let _ =
                array.get(child_view.topic_children_tokens, child_topic_index)
                |> result.map(dromel.focus)
              Nil
            }
          }
        }
      }
    }
  }
}

/// Check if can navigate back
pub fn can_navigate_back(container) -> Bool {
  case get_active_topic_view(container) {
    Ok(topic_view) -> history_graph.can_go_back(topic_view.entry_id)
    Error(_) -> False
  }
}

/// Check if can navigate forward
pub fn can_navigate_forward(container) -> Bool {
  case get_active_topic_view(container) {
    Ok(topic_view) -> history_graph.can_go_forward(topic_view.entry_id)
    Error(_) -> False
  }
}

fn handle_topic_view_keydown(container) {
  dromel.add_event_listener(container, "keydown", fn(event) {
    case event.ctrl_key(event), event.shift_key(event), event.key(event) {
      False, False, "h" -> {
        event.prevent_default(event)
        case get_active_topic_view(container) {
          Error(Nil) -> io.println_error("No active topic view")
          Ok(view) -> {
            case
              array.get(
                view.topic_children_tokens,
                get_current_child_topic_index(container),
              )
              |> result.try(dromel.get_data(_, topic_key))
              |> result.map(audit_data.Topic)
            {
              Error(Nil) -> io.println_error("Unable to read child topic")
              Ok(topic) -> {
                navigate_to_new_entry(container, topic)
              }
            }
          }
        }
      }

      False, False, "p" -> {
        event.prevent_default(event)
        navigate_back(container)
      }

      True, False, "p" -> {
        event.prevent_default(event)
        navigate_forward(container)
      }

      False, False, "ArrowDown" | False, False, "," -> {
        event.prevent_default(event)
        case get_active_topic_view(container) {
          Ok(view) -> {
            let new_index = get_current_child_topic_index(container) + 1

            case view.topic_children_tokens |> array.get(new_index) {
              Ok(el) -> {
                dromel.focus(el)
                set_current_child_topic_index(container, new_index)
              }
              Error(Nil) -> {
                io.println("no next child")
              }
            }

            Nil
          }
          Error(Nil) -> {
            echo "no active view"
            Nil
          }
        }
        Nil
      }

      False, False, "ArrowUp" | False, False, "e" -> {
        event.prevent_default(event)
        case get_active_topic_view(container) {
          Ok(view) -> {
            let new_index = get_current_child_topic_index(container) - 1

            case view.topic_children_tokens |> array.get(new_index) {
              Ok(el) -> {
                dromel.focus(el)
                set_current_child_topic_index(container, new_index)
              }
              Error(Nil) -> {
                io.println("no prior child")
              }
            }

            Nil
          }
          Error(Nil) -> {
            echo "no active view"
            Nil
          }
        }
        Nil
      }
      _, _, _ -> Nil
    }
  })

  container
}

fn populate_topic_name(
  chain_entry: history_graph.HistoryEntry,
  item: dromel.Element,
) {
  // Fetch topic metadata and update the text
  audit_data.with_topic_metadata(
    audit_data.Topic(id: chain_entry.topic_id),
    fn(result) {
      case result {
        Ok(metadata) -> {
          let name = audit_data.topic_metadata_highlighted_name(metadata)
          let _ = dromel.set_inner_html(item, name)
          Nil
        }
        Error(_) -> {
          let _ = dromel.set_inner_text(item, "Unknown")
          Nil
        }
      }
    },
  )
}

fn populate_references_panel(
  container: element.Element,
  panel: element.Element,
  references: List(audit_data.Topic),
) {
  case references {
    [] -> {
      let _ =
        panel
        |> dromel.set_inner_html(
          "<div style='color: var(--color-body-text); font-size: 0.9rem;'>No references</div>",
        )
      Nil
    }
    _ -> {
      list.each(references, fn(ref_topic) {
        let item =
          dromel.new_div()
          |> dromel.set_style(
            "padding: 0.25rem 0.5rem; cursor: pointer; color: var(--color-body-text); font-size: 0.85rem;",
          )
          |> dromel.set_inner_text("Loading...")
          |> dromel.add_event_listener("click", fn(_event) {
            navigate_to_new_entry(container, ref_topic)
          })
          |> dromel.add_event_listener("mouseenter", fn(ev) {
            case dromel.cast(event.target(ev)) {
              Ok(target) -> {
                let _ =
                  target
                  |> dromel.add_style("background: var(--color-hover-bg);")
                Nil
              }
              Error(_) -> Nil
            }
          })
          |> dromel.add_event_listener("mouseleave", fn(ev) {
            case dromel.cast(event.target(ev)) {
              Ok(target) -> {
                let _ =
                  target
                  |> dromel.add_style("background: transparent;")
                Nil
              }
              Error(_) -> Nil
            }
          })

        let _ = panel |> dromel.append_child(item)

        // Fetch the topic name
        audit_data.with_topic_metadata(ref_topic, fn(result) {
          case result {
            Ok(metadata) -> {
              let name = audit_data.topic_metadata_highlighted_name(metadata)
              let _ = dromel.set_inner_html(item, name)
              Nil
            }
            Error(_) -> {
              let _ = dromel.set_inner_text(item, "Unknown")
              Nil
            }
          }
        })
      })
    }
  }
}
