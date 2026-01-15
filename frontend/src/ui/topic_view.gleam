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
//// let root_entry_id = navigation_history.create_root(
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
////     case navigation_history.navigate_to(
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
import gleam/result
import navigation_history
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
    element: element.Element,
    children_topic_tokens: array.Array(element.Element),
  )
}

// ============================================================================
// FFI Bindings for State Management
// ============================================================================

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

pub fn setup_view_container() {
  let view_container =
    dromel.new_div()
    |> dromel.set_style("flex: 1; min-height: 0")
    |> handle_topic_view_keydown

  let _ = audit_data.app_element() |> dromel.append_child(view_container)

  audit_data.set_topic_view_container(view_container)
}

fn mount_topic_view(
  container: element.Element,
  entry_id: String,
  _topic_id: String,
) -> element.Element {
  // Create the view container
  let view_element =
    dromel.new_div()
    |> dromel.set_data(elements.nav_entry_id, entry_id)
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(
      "background: var(--color-code-bg); display: none; box-sizing: border-box; margin: 1rem auto;",
    )
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text);'>Loading...</div>",
    )

  let _ = container |> dromel.append_child(view_element)

  view_element
}

// ============================================================================
// View Visibility Management
// ============================================================================

fn show_view(view_element: element.Element) -> Nil {
  let _ =
    view_element
    |> dromel.add_style("display: block;")
  Nil
}

fn hide_view(view_element: element.Element) -> Nil {
  let _ =
    view_element
    |> dromel.add_style("display: none;")
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
  let new_entry = case get_active_topic_view(container) {
    Ok(active_view) -> {
      // If there is an active view, hide it
      hide_view(active_view.element)

      case
        navigation_history.go_to_new_entry(
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
    Error(Nil) -> navigation_history.create_root(topic)
  }

  // Create new view
  let view_element =
    mount_topic_view(container, new_entry.id, new_entry.topic_id)

  // Initialize view state
  let view =
    TopicView(
      entry_id: new_entry.id,
      topic_id: new_entry.topic_id,
      element: view_element,
      children_topic_tokens: array.from_list([]),
    )
  set_topic_view(new_entry.id, view)

  // Show the new view
  set_active_topic_view(container, view)
  set_current_child_topic_index(container, 0)
  show_view(view.element)

  // Load source text
  audit_data.with_source_text(
    audit_data.Topic(id: new_entry.topic_id),
    fn(result) {
      case result {
        Ok(source_text) -> {
          let _ = view.element |> dromel.set_inner_html(source_text)

          let children =
            dromel.query_element_all(view.element, elements.source_topic_tokens)

          set_topic_view(
            new_entry.id,
            TopicView(..view, children_topic_tokens: children),
          )

          let _ = array.get(children, 0) |> result.map(dromel.focus)

          Nil
        }
        Error(error) -> {
          let _ =
            view.element
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
}

/// Navigate back in history
pub fn navigate_back(container) -> Nil {
  case get_active_topic_view(container) {
    Error(Nil) ->
      snag.new("Cannot navigate back, there is no active view")
      |> snag.line_print
      |> io.println_error

    Ok(active_view) -> {
      case navigation_history.go_back(active_view.entry_id) {
        Error(snag) ->
          snag.layer(snag, "Cannot navigate back")
          |> snag.line_print
          |> io.println_error

        Ok(#(parent_entry, child_topic_index)) -> {
          case get_topic_view(parent_entry.id) {
            Ok(parent_view) -> {
              hide_view(active_view.element)
              set_active_topic_view(container, parent_view)
              set_current_child_topic_index(container, child_topic_index)
              let _ =
                array.get(parent_view.children_topic_tokens, child_topic_index)
                |> result.map(dromel.focus)
              show_view(parent_view.element)
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
pub fn go_forward(container) -> Nil {
  case get_active_topic_view(container) {
    Error(Nil) ->
      snag.new("Cannot navigate Forward, there is no active view")
      |> snag.line_print
      |> io.println_error

    Ok(active_view) -> {
      case navigation_history.go_forward(active_view.entry_id) {
        Error(snag) ->
          snag.layer(snag, "Cannot navigate forward")
          |> snag.line_print
          |> io.println_error

        Ok(child_entry_id) -> {
          case get_topic_view(child_entry_id) {
            Error(_) ->
              snag.new("Child view not found for entry: " <> child_entry_id)
              |> snag.line_print
              |> io.println_error

            Ok(child_view) -> {
              hide_view(active_view.element)
              set_active_topic_view(container, child_view)
              set_current_child_topic_index(container, todo)
              let _ =
                array.get(child_view.children_topic_tokens, todo)
                |> result.map(dromel.focus)
              show_view(child_view.element)
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
    Ok(topic_view) -> navigation_history.can_go_back(topic_view.entry_id)
    Error(_) -> False
  }
}

/// Check if can navigate forward
pub fn can_navigate_forward(container) -> Bool {
  case get_active_topic_view(container) {
    Ok(topic_view) -> navigation_history.can_go_forward(topic_view.entry_id)
    Error(_) -> False
  }
}

fn handle_topic_view_keydown(container) {
  dromel.add_event_listener(container, "keydown", fn(event) {
    echo "got key " <> event.key(event)
    case event.ctrl_key(event), event.shift_key(event), event.key(event) {
      _, _, "h" -> {
        event.prevent_default(event)
        case get_active_topic_view(container) {
          Error(Nil) -> io.println_error("No active topic view")
          Ok(view) -> {
            case
              array.get(
                view.children_topic_tokens,
                get_current_child_topic_index(container),
              )
              |> result.try(dromel.get_data(_, topic_key))
              |> result.map(audit_data.Topic)
            {
              Error(Nil) -> io.println_error("Unable to fetch child topic")
              Ok(topic) -> {
                navigate_to_new_entry(container, topic)
              }
            }
          }
        }
      }

      False, False, "ArrowDown" -> {
        event.prevent_default(event)
        case get_active_topic_view(container) {
          Ok(view) -> {
            let new_index = get_current_child_topic_index(container) + 1

            case view.children_topic_tokens |> array.get(new_index) {
              Ok(el) -> {
                dromel.focus(el)
                io.println(
                  "Focusing element with topic "
                  <> dromel.get_data(el, elements.token_topic_id_key)
                  |> result.unwrap("None"),
                )
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

      False, False, "ArrowUp" -> {
        event.prevent_default(event)
        case get_active_topic_view(container) {
          Ok(view) -> {
            let new_index = get_current_child_topic_index(container) - 1

            case view.children_topic_tokens |> array.get(new_index) {
              Ok(el) -> {
                dromel.focus(el)
                io.println(
                  "Focusing element with topic "
                  <> dromel.get_data(el, elements.token_topic_id_key)
                  |> result.unwrap("None"),
                )
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
