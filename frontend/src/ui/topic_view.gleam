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
import navigation_history
import plinth/browser/element
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
    is_visible: Bool,
  )
}

// ============================================================================
// FFI Bindings for State Management
// ============================================================================

@external(javascript, "../mem_ffi.mjs", "get_topic_view")
fn get_topic_view(entry_id: String) -> Result(TopicView, Nil)

@external(javascript, "../mem_ffi.mjs", "set_topic_view")
fn set_topic_view(entry_id: String, view: TopicView) -> Nil

@external(javascript, "../mem_ffi.mjs", "get_active_view_entry_id")
fn get_active_view_entry_id() -> Result(String, Nil)

@external(javascript, "../mem_ffi.mjs", "set_active_view_entry_id")
fn set_active_view_entry_id(entry_id: String) -> Nil

// ============================================================================
// View Mounting
// ============================================================================

fn mount_topic_view(
  container: element.Element,
  entry_id: String,
  _topic_id: String,
) -> element.Element {
  // Create the view container
  let view_element =
    dromel.new_div()
    |> dromel.set_attribute("data-entry-id", entry_id)
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
// Rendering Functions
// ============================================================================

fn render_source_text(view_element: element.Element, html: String) -> Nil {
  let _ = view_element |> dromel.set_inner_html(html)
  Nil
}

fn render_error(view_element: element.Element, error: String) -> Nil {
  let _ =
    view_element
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text); padding: 1rem;'>Error loading source:<br><br>"
      <> error
      <> "</div>",
    )
  Nil
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

/// Switch to a different view by hiding all others and showing the specified one
fn switch_to_view(entry_id: String, view: TopicView) -> Nil {
  hide_all_views_except(entry_id)
  show_view(view.element)
  set_active_view_entry_id(entry_id)
  set_topic_view(entry_id, TopicView(..view, is_visible: True))
}

// ============================================================================
// Public API
// ============================================================================

/// Create or get a view for a navigation entry
/// If the view already exists, it will be reused
/// The view will be made visible and set as the active view
pub fn navigate_to_entry(
  container: element.Element,
  entry_id: String,
) -> Result(Nil, snag.Snag) {
  // Get the navigation entry to retrieve topic_id
  case navigation_history.get_entry(entry_id) {
    Error(err) -> Error(err)
    Ok(entry) -> {
      // Check if view already exists
      case get_topic_view(entry_id) {
        Ok(existing_view) -> {
          // View exists, just show it and hide others
          switch_to_view(entry_id, existing_view)
          Ok(Nil)
        }
        Error(Nil) -> {
          // Create new view
          let view_element = mount_topic_view(container, entry_id, entry.topic_id)

          // Initialize view state
          let view =
            TopicView(
              entry_id: entry_id,
              topic_id: entry.topic_id,
              element: view_element,
              is_visible: False,
            )
          set_topic_view(entry_id, view)

          // Hide all other views and show this one
          switch_to_view(entry_id, view)

          // Load source text
          audit_data.with_source_text(
            audit_data.Topic(id: entry.topic_id),
            fn(result) {
              case result {
                Ok(html) -> render_source_text(view_element, html)
                Error(err) -> render_error(view_element, snag.line_print(err))
              }
            },
          )

          Ok(Nil)
        }
      }
    }
  }
}

/// Hide all views except the specified entry_id
fn hide_all_views_except(except_entry_id: String) -> Nil {
  // Note: In a full implementation, we'd iterate through all views
  // For now, we'll hide the currently active view if it's different
  case get_active_view_entry_id() {
    Ok(active_entry_id) if active_entry_id != except_entry_id -> {
      case get_topic_view(active_entry_id) {
        Ok(view) -> {
          hide_view(view.element)
          set_topic_view(active_entry_id, TopicView(..view, is_visible: False))
        }
        Error(_) -> Nil
      }
    }
    _ -> Nil
  }
}

/// Navigate back in history
pub fn go_back() -> Result(Nil, snag.Snag) {
  case get_active_view_entry_id() {
    Error(_) -> snag.error("No active view")
    Ok(current_entry_id) -> {
      case navigation_history.go_back(current_entry_id) {
        Error(err) -> Error(err)
        Ok(#(parent_entry_id, _line_number)) -> {
          // For now, we'll just navigate to the parent entry
          // TODO: Scroll to the line_number
          case get_topic_view(parent_entry_id) {
            Ok(parent_view) -> {
              switch_to_view(parent_entry_id, parent_view)
              Ok(Nil)
            }
            Error(_) ->
              snag.error("Parent view not found for entry: " <> parent_entry_id)
          }
        }
      }
    }
  }
}

/// Navigate forward in history (to most recent child)
pub fn go_forward() -> Result(Nil, snag.Snag) {
  case get_active_view_entry_id() {
    Error(_) -> snag.error("No active view")
    Ok(current_entry_id) -> {
      case navigation_history.go_forward(current_entry_id) {
        Error(err) -> Error(err)
        Ok(child_entry_id) -> {
          case get_topic_view(child_entry_id) {
            Ok(child_view) -> {
              switch_to_view(child_entry_id, child_view)
              Ok(Nil)
            }
            Error(_) ->
              snag.error("Child view not found for entry: " <> child_entry_id)
          }
        }
      }
    }
  }
}

/// Get the currently active entry ID
pub fn get_active_entry_id() -> Result(String, snag.Snag) {
  case get_active_view_entry_id() {
    Ok(entry_id) -> Ok(entry_id)
    Error(_) -> snag.error("No active view")
  }
}

/// Check if can navigate back
pub fn can_navigate_back() -> Bool {
  case get_active_view_entry_id() {
    Ok(entry_id) -> navigation_history.can_go_back(entry_id)
    Error(_) -> False
  }
}

/// Check if can navigate forward
pub fn can_navigate_forward() -> Bool {
  case get_active_view_entry_id() {
    Ok(entry_id) -> navigation_history.can_go_forward(entry_id)
    Error(_) -> False
  }
}
