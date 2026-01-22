//// Topic View Module
////
//// This module manages the display of source text views with navigation history support.
//// Only one view exists in the DOM at a time - when navigating, the current view's
//// scroll position is saved and its DOM elements are removed. When navigating back
//// or forward, the view is re-created and scroll position is restored.
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
import gleam/option
import gleam/result
import history_graph
import plinth/browser/element
import plinth/browser/event
import snag
import ui/elements
import ui/icons

// ============================================================================
// Topic View State
// ============================================================================

/// TopicView stores metadata about a view. DOM elements are created/destroyed
/// on navigation, but scroll_position is preserved to restore the view state.
pub type TopicView {
  TopicView(entry_id: String, topic_id: String, scroll_position: Float)
}

// ============================================================================
// Active View Elements (transient, only exists for currently displayed view)
// ============================================================================

type ActiveViewElements {
  ActiveViewElements(
    previous_topic_scope: element.Element,
    previous_topic_panel: element.Element,
    previous_topic_container: element.Element,
    topic_scope: element.Element,
    topic_panel: element.Element,
    topic_container: element.Element,
    references_panel: element.Element,
    references_container: element.Element,
    topic_children_tokens: array.Array(element.Element),
  )
}

@external(javascript, "../mem_ffi.mjs", "get_active_view_elements")
fn get_active_view_elements() -> Result(ActiveViewElements, Nil)

@external(javascript, "../mem_ffi.mjs", "set_active_view_elements")
fn set_active_view_elements(elements: ActiveViewElements) -> Nil

@external(javascript, "../mem_ffi.mjs", "clear_active_view_elements")
fn clear_active_view_elements() -> Nil

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
// View Mounting and Removal
// ============================================================================

const panel_style = "border-radius: 8px; border: 1px solid var(--color-body-border); padding: 0.5rem; background: var(--color-code-bg); max-height: 100%;"

const scope_style = "display: inline-flex; align-items: center; gap: 0.25rem; margin-left: 0.5rem; margin-bottom: 0.5rem; direction: rtl; overflow: hidden; max-width: 40ch;"

const footer_style = "position: absolute; bottom: -1rem; right: 0.5rem;"

fn mount_topic_view(container: element.Element) -> ActiveViewElements {
  // Create the previous topic panel element (muted border)
  let previous_topic_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let previous_topic_scope =
    dromel.new_div()
    |> dromel.set_style(scope_style)

  let previous_topic_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Previous Topic")
    |> dromel.set_style(footer_style)

  let previous_topic_container =
    dromel.new_div()
    |> dromel.set_style("position: relative; padding-top: 0.5rem;")
    |> dromel.append_child(previous_topic_scope)
    |> dromel.append_child(previous_topic_panel)
    |> dromel.append_child(previous_topic_footer)

  // Create the source view element
  let topic_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text);'>Loading topic source...</div>",
    )

  let topic_scope =
    dromel.new_div()
    |> dromel.set_style(scope_style)

  let topic_footer =
    dromel.new_div()
    |> dromel.set_style(footer_style)
    |> dromel.set_inner_text("Current Topic")

  let topic_container =
    dromel.new_div()
    |> dromel.set_style("position: relative; padding-top: 0.5rem;")
    |> dromel.append_child(topic_scope)
    |> dromel.append_child(topic_panel)
    |> dromel.append_child(topic_footer)

  // Create the references panel element
  let references_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(
      "min-height: 0; display: flex; flex-direction: column; gap: 0.5rem; height: 100%; width: unset;",
    )

  let references_footer =
    dromel.new_div()
    |> dromel.set_inner_text("References")
    |> dromel.set_style(footer_style)

  let references_container =
    dromel.new_div()
    |> dromel.set_style(
      "position: relative; padding-top: 0.5rem; max-height: 100%;",
    )
    |> dromel.append_child(references_footer)
    |> dromel.append_child(references_panel)

  let _ = container |> dromel.append_child(previous_topic_container)
  let _ = container |> dromel.append_child(topic_container)
  let _ = container |> dromel.append_child(references_container)

  let elements =
    ActiveViewElements(
      previous_topic_scope:,
      previous_topic_panel:,
      previous_topic_container:,
      topic_scope:,
      topic_panel:,
      topic_container:,
      references_panel:,
      references_container:,
      topic_children_tokens: array.from_list([]),
    )

  set_active_view_elements(elements)

  elements
}

/// Save scroll position and remove DOM elements for the active view
fn remove_active_view(container: element.Element) -> Nil {
  case get_active_topic_view(container), get_active_view_elements() {
    Ok(view), Ok(elements) -> {
      // Save scroll position before removing
      let scroll_pos = dromel.get_scroll_top(elements.topic_panel)
      let updated_view = TopicView(..view, scroll_position: scroll_pos)
      set_topic_view(view.entry_id, updated_view)

      // Remove DOM elements
      let _ = dromel.remove(elements.previous_topic_container)
      let _ = dromel.remove(elements.topic_container)
      let _ = dromel.remove(elements.references_container)

      clear_active_view_elements()

      Nil
    }
    _, _ -> Nil
  }
}

// ============================================================================
// Source Text Loading Callbacks
// ============================================================================

/// Callback for loading source text into a new view (scroll position 0, focus first child)
fn on_source_text_loaded_new(
  elements: ActiveViewElements,
  topic: audit_data.Topic,
) -> fn(Result(String, snag.Snag)) -> Nil {
  fn(result) {
    case result {
      Ok(source_text) -> {
        let _ = elements.topic_panel |> dromel.set_inner_html(source_text)

        let children =
          dromel.query_element_all(
            elements.topic_panel,
            elements.source_topic_tokens,
          )

        set_active_view_elements(
          ActiveViewElements(..elements, topic_children_tokens: children),
        )

        let _ = array.get(children, 0) |> result.map(dromel.focus)

        // Update the scope breadcrumb
        populate_topic_scope(elements.topic_scope, topic)

        Nil
      }

      Error(error) -> {
        let _ =
          elements.topic_panel
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
  }
}

/// Callback for loading source text when restoring a view (restore scroll position, focus specific child)
fn on_source_text_loaded_restore(
  elements: ActiveViewElements,
  scroll_position: Float,
  child_topic_index: Int,
  topic: audit_data.Topic,
) -> fn(Result(String, snag.Snag)) -> Nil {
  fn(result) {
    case result {
      Ok(source_text) -> {
        let _ = elements.topic_panel |> dromel.set_inner_html(source_text)

        // Restore scroll position
        dromel.set_scroll_top(elements.topic_panel, scroll_position)

        let children =
          dromel.query_element_all(
            elements.topic_panel,
            elements.source_topic_tokens,
          )

        set_active_view_elements(
          ActiveViewElements(..elements, topic_children_tokens: children),
        )

        let _ =
          array.get(children, child_topic_index) |> result.map(dromel.focus)

        // Update the scope breadcrumb
        populate_topic_scope(elements.topic_scope, topic)

        Nil
      }

      Error(error) -> {
        let _ =
          elements.topic_panel
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
  }
}

/// Callback for loading topic metadata and populating the references panel
fn on_topic_metadata_loaded(
  elements: ActiveViewElements,
) -> fn(Result(audit_data.TopicMetadata, snag.Snag)) -> Nil {
  fn(metadata) {
    case metadata {
      Ok(metadata) -> {
        case metadata {
          audit_data.NamedTopic(references:, ..) -> {
            populate_references_panel(elements.references_panel, references)
          }
          audit_data.UnnamedTopic(..) -> {
            let _ =
              elements.references_panel
              |> dromel.set_inner_html(
                "<div style='color: var(--color-body-text); font-size: 0.9rem;'>No references</div>",
              )
            Nil
          }
        }

        audit_data.with_in_scope_files(fn(in_scope_files) {
          case list.contains(in_scope_files, metadata.scope.container) {
            True -> Nil
            False -> {
              dromel.add_style(
                elements.topic_panel,
                "border-color: var(--color-body-out-of-scope-bg)",
              )
              Nil
            }
          }
        })
      }
      Error(_) -> {
        let _ =
          elements.references_panel
          |> dromel.set_inner_html(
            "<div style='color: var(--color-body-text); font-size: 0.9rem;'>Unable to load references</div>",
          )
        Nil
      }
    }
  }
}

/// Callback for loading source text into the previous topic panel
fn on_previous_source_text_loaded(
  elements: ActiveViewElements,
  child_topic_index: Int,
  scroll_position: Float,
  topic: audit_data.Topic,
) -> fn(Result(String, snag.Snag)) -> Nil {
  fn(result) {
    case result {
      Ok(source_text) -> {
        let _ =
          elements.previous_topic_panel |> dromel.set_inner_html(source_text)
        dromel.set_scroll_top(elements.previous_topic_panel, scroll_position)

        // Highlight the previous topic index
        let _ =
          dromel.query_element_all(
            elements.previous_topic_panel,
            elements.source_topic_tokens,
          )
          |> array.get(child_topic_index)
          |> result.map(fn(element) {
            element |> dromel.add_style("text-decoration: underline;")
          })

        // Update the scope breadcrumb
        populate_topic_scope(elements.previous_topic_scope, topic)

        Nil
      }
      Error(_) -> {
        // Silently fail - previous topic panel is optional
        Nil
      }
    }
  }
}

/// Load the previous topic panel content based on the parent entry in history
fn load_previous_topic_panel(
  entry_id: String,
  elements: ActiveViewElements,
) -> Nil {
  case history_graph.get_history_entry(entry_id) {
    Error(Nil) -> set_no_previous_topic(elements)
    Ok(entry) ->
      case entry.parent {
        option.None -> set_no_previous_topic(elements)
        option.Some(history_graph.Relative(id: parent_id, child_topic_index:)) ->
          case history_graph.get_history_entry(parent_id) {
            Error(Nil) -> set_no_previous_topic(elements)
            Ok(parent_entry) -> {
              // Get the stored scroll position for the parent view
              let scroll_position = case get_topic_view(parent_entry.id) {
                Ok(parent_view) -> parent_view.scroll_position
                Error(Nil) -> 0.0
              }

              let topic = audit_data.Topic(id: parent_entry.topic_id)
              audit_data.with_source_text(
                topic,
                on_previous_source_text_loaded(
                  elements,
                  child_topic_index,
                  scroll_position,
                  topic,
                ),
              )
            }
          }
      }
  }
}

fn set_no_previous_topic(elements: ActiveViewElements) -> Nil {
  let _ =
    elements.previous_topic_panel
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text); font-size: 0.9rem;'>No previous topic</div>",
    )
  let _ = elements.previous_topic_scope |> dromel.set_inner_html("")
  Nil
}

// ============================================================================
// Topic Scope Breadcrumb
// ============================================================================

const scope_item_style = "color: var(--color-body-text); white-space: nowrap;"

const scope_chevron_style = "display: inline-flex; align-items: center; opacity: 0.6; width: 0.75em; height: 0.75em; line-height: 1; flex-shrink: 0;"

/// Populate a scope container with a breadcrumb showing Component > Member > Name
fn populate_topic_scope(
  scope_container: element.Element,
  topic: audit_data.Topic,
) -> Nil {
  audit_data.with_topic_metadata(topic, fn(result) {
    case result {
      Ok(metadata) -> {
        mount_scope_breadcrumb(scope_container, metadata)
      }
      Error(_) -> {
        let _ = dromel.set_inner_html(scope_container, "")
        Nil
      }
    }
  })
}

/// Mount a breadcrumb display for a topic's scope
/// Creates breadcrumb elements separated by chevron_right icons
/// Similar pattern to mount_history_breadcrumb in history_graph.gleam
fn mount_scope_breadcrumb(
  container: element.Element,
  metadata: audit_data.TopicMetadata,
) -> Nil {
  // Clear the container first
  let _ = dromel.set_inner_html(container, "")

  // Build list of scope items based on scope type
  // Only show component and optionally member (never the topic name)
  // Reverse because container has direction: rtl, so last items appear first (rightmost)
  // Special case: if the topic is a contract, show its name instead of the file name
  let scope_items =
    case metadata.scope {
      audit_data.Container(..) -> [
        metadata.topic,
      ]
      audit_data.Component(component:, ..) -> [component]
      audit_data.Member(component:, member:, ..) -> [
        component,
        member,
      ]
      audit_data.SemanticBlock(component:, member:, ..) -> [
        component,
        member,
      ]
    }
    |> list.reverse

  // Create breadcrumb elements for each item in the scope
  list.index_map(scope_items, fn(item, index) {
    // Add chevron delimiter before each item except the first
    case index > 0 {
      True -> {
        let _ =
          dromel.new_span()
          |> dromel.set_inner_html(icons.chevron_right_breadcrumb)
          |> dromel.set_style(scope_chevron_style)
          |> dromel.append_child(to: container)
        Nil
      }
      False -> Nil
    }

    // Create the text span
    let text_span =
      dromel.new_span()
      |> dromel.set_inner_text("...")
      |> dromel.set_style(scope_item_style)

    let _ = dromel.append_child(container, text_span)

    audit_data.with_topic_metadata(item, fn(result) {
      case result {
        Ok(metadata) -> {
          let name = audit_data.topic_metadata_highlighted_name(metadata)
          let _ = dromel.set_inner_html(text_span, name)
          Nil
        }
        Error(_) -> {
          let _ = dromel.set_inner_text(text_span, "?")
          Nil
        }
      }
    })
  })

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
          // Remove the active view's DOM elements (saves scroll position)
          remove_active_view(container)

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

      // Create new view DOM elements
      let elements = mount_topic_view(container)

      // Initialize view state (scroll position starts at 0 for new views)
      let view =
        TopicView(
          entry_id: new_entry.id,
          topic_id: new_entry.topic_id,
          scroll_position: 0.0,
        )
      set_topic_view(new_entry.id, view)

      // Set as active view
      set_active_topic_view(container, view)
      set_current_child_topic_index(container, 0)

      // Update the URL to reflect the active topic
      update_url_for_topic(new_entry.topic_id)

      // Update the breadcrumb
      history_graph.mount_history_breadcrumb(
        get_history_container(),
        new_entry,
        populate_topic_name,
      )

      // Load previous topic panel content
      load_previous_topic_panel(new_entry.id, elements)

      // Load source text
      audit_data.with_source_text(
        audit_data.Topic(id: new_entry.topic_id),
        on_source_text_loaded_new(elements, topic),
      )

      // Load topic metadata and populate references panel
      audit_data.with_topic_metadata(topic, on_topic_metadata_loaded(elements))
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

              // Remove current view's DOM elements (saves scroll position)
              remove_active_view(container)

              // Re-create DOM elements for the parent view
              let elements = mount_topic_view(container)

              set_active_topic_view(container, parent_view)
              set_current_child_topic_index(container, child_topic_index)

              // Update the URL to reflect the active topic
              update_url_for_topic(parent_entry.topic_id)

              history_graph.mount_history_breadcrumb(
                get_history_container(),
                parent_entry,
                populate_topic_name,
              )

              // Load previous topic panel content
              load_previous_topic_panel(parent_entry.id, elements)

              // Load source text and restore scroll position
              let parent_topic = audit_data.Topic(id: parent_entry.topic_id)
              audit_data.with_source_text(
                parent_topic,
                on_source_text_loaded_restore(
                  elements,
                  parent_view.scroll_position,
                  child_topic_index,
                  parent_topic,
                ),
              )

              // Load topic metadata and populate references panel
              audit_data.with_topic_metadata(
                parent_topic,
                on_topic_metadata_loaded(elements),
              )

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

/// Navigate forward in history (to most recent child)
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
          case get_topic_view(child_entry.id) {
            Error(Nil) ->
              snag.new("Child view not found for entry: " <> child_entry.id)
              |> snag.line_print
              |> io.println_error

            Ok(child_view) -> {
              // Remove current view's DOM elements (saves scroll position)
              remove_active_view(container)

              // Re-create DOM elements for the child view
              let elements = mount_topic_view(container)

              set_active_topic_view(container, child_view)
              set_current_child_topic_index(container, child_topic_index)

              // Update the URL to reflect the active topic
              update_url_for_topic(child_entry.topic_id)

              history_graph.mount_history_breadcrumb(
                get_history_container(),
                child_entry,
                populate_topic_name,
              )

              // Load previous topic panel content
              load_previous_topic_panel(child_entry.id, elements)

              // Load source text and restore scroll position
              let child_topic = audit_data.Topic(id: child_entry.topic_id)
              audit_data.with_source_text(
                child_topic,
                on_source_text_loaded_restore(
                  elements,
                  child_view.scroll_position,
                  child_topic_index,
                  child_topic,
                ),
              )

              // Load topic metadata and populate references panel
              audit_data.with_topic_metadata(
                child_topic,
                on_topic_metadata_loaded(elements),
              )

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
        case get_active_view_elements() {
          Error(Nil) -> io.println_error("No active topic view")
          Ok(elements) -> {
            case
              array.get(
                elements.topic_children_tokens,
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
        case get_active_view_elements() {
          Ok(elements) -> {
            let new_index = get_current_child_topic_index(container) + 1

            case elements.topic_children_tokens |> array.get(new_index) {
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
            io.println_error("no active view")
            Nil
          }
        }
        Nil
      }

      False, False, "ArrowUp" | False, False, "e" -> {
        event.prevent_default(event)
        case get_active_view_elements() {
          Ok(elements) -> {
            let new_index = get_current_child_topic_index(container) - 1

            case elements.topic_children_tokens |> array.get(new_index) {
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
            io.println_error("no active view")
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

const reference_class_container = dromel.Class("topic-reference-container")

const reference_title_class = dromel.Class("topic-reference-title")

const reference_source_class = dromel.Class("topic-reference-source")

fn populate_references_panel(
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
        let reference_scope =
          dromel.new_div()
          |> dromel.set_class(reference_title_class)
          |> dromel.set_style(scope_style)

        let reference_source =
          dromel.new_div()
          |> dromel.set_class(reference_source_class)
          |> dromel.add_class(elements.source_container_class)
          |> dromel.set_style(panel_style)
          |> dromel.add_style("padding-left: 0.5rem;")

        let reference_container =
          dromel.new_div()
          |> dromel.set_class(reference_class_container)
          |> dromel.set_style("max-height: 100%;")
          |> dromel.append_child(reference_scope)
          |> dromel.append_child(reference_source)

        let _ = panel |> dromel.append_child(reference_container)

        // Populate the scope breadcrumb
        populate_topic_scope(reference_scope, ref_topic)

        audit_data.with_source_text(ref_topic, fn(result) {
          case result {
            Ok(source_text) -> {
              let _ = reference_source |> dromel.set_inner_html(source_text)

              Nil
            }

            Error(error) -> {
              let _ =
                reference_source
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
        })
      })
    }
  }
}
