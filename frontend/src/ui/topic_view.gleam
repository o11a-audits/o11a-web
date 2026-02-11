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
import context
import core/log
import dromel
import gleam/int
import gleam/io
import gleam/javascript/array
import gleam/list
import gleam/result
import gleam/string
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
/// on navigation.
pub type TopicView {
  TopicView(entry_id: String, topic_id: String)
}

/// Re-export ActivePanel from history_graph for convenience
pub type ActivePanel =
  history_graph.ActivePanel

/// Identifies which token array field to update in ActiveViewElements
type TokenField {
  MentionsPanelTokens
  CommentsPanelTokens
  TopicPanelTokens
  ReferencesPanelTokens
}

/// Configuration for rendering a panel with grouped source containers
type GroupedSourcePanelConfig {
  GroupedSourcePanelConfig(
    /// The view container element (for state like pending focus)
    container: element.Element,
    /// The panel element to render into
    panel: element.Element,
    /// Which token field to update when gathering tokens
    token_field: TokenField,
  )
}

// ============================================================================
// Active View Elements (transient, only exists for currently displayed view)
// ============================================================================

const topic_panel_id = dromel.Id("topic-panel")

const expanded_references_panel_id = dromel.Id("expanded-references-panel")

type ActiveViewElements {
  ActiveViewElements(
    mentions_panel: element.Element,
    mentions_container: element.Element,
    comments_panel: element.Element,
    comments_container: element.Element,
    comments_input: element.Element,
    topic_panel: element.Element,
    topic_container: element.Element,
    expanded_references_panel: element.Element,
    expanded_references_container: element.Element,
    mentions_tokens: array.Array(element.Element),
    comments_tokens: array.Array(element.Element),
    topic_children_tokens: array.Array(element.Element),
    expanded_references_tokens: array.Array(element.Element),
  )
}

@external(javascript, "../mem_ffi.mjs", "get_active_view_elements")
fn get_active_view_elements() -> Result(ActiveViewElements, Nil)

@external(javascript, "../mem_ffi.mjs", "set_active_view_elements")
fn set_active_view_elements(elements: ActiveViewElements) -> Nil

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
      "display: flex; flex: 1; min-height: 0; justify-content: center; gap: 0.25rem; background: var(--color-body-bg);",
    )

  let _ = audit_data.app_element() |> dromel.append_child(view_container)

  set_topic_view_container(view_container)

  view_container
}

@external(javascript, "../mem_ffi.mjs", "get_topic_view")
fn get_topic_view(entry_id: String) -> Result(TopicView, Nil)

@external(javascript, "../mem_ffi.mjs", "set_topic_view")
fn set_topic_view(entry_id: String, view: TopicView) -> Nil

const active_topic_view_key = dromel.DataKey("active_topic_view")

const active_topic_style_id = "active-topic-highlight-style"

fn set_active_topic_view(
  container: element.Element,
  view: TopicView,
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
) -> Nil {
  let _ = dromel.set_data(container, active_topic_view_key, view.entry_id)
  set_active_topic_highlight_style(view.topic_id, metadata)
  Nil
}

/// Flatten expanded_references into a list of topic IDs
fn flatten_expanded_references(
  expanded_references: List(audit_data.ReferenceGroup),
) -> List(String) {
  list.flat_map(expanded_references, fn(group) {
    let scope_ids = [group.scope.id]
    let scope_ref_ids =
      list.map(group.scope_references, fn(entry) { entry.reference_topic.id })
    let nested_ids =
      list.flat_map(group.nested_references, fn(nested_group) {
        [
          nested_group.subscope.id,
          ..list.map(nested_group.references, fn(entry) {
            entry.reference_topic.id
          })
        ]
      })
    list.flatten([scope_ids, scope_ref_ids, nested_ids])
  })
}

/// Sets a dynamic CSS rule on the app element to highlight elements with data-topic matching the active topic
fn set_active_topic_highlight_style(
  topic_id: String,
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
) -> Nil {
  // Build style for the active topic (solid underline)
  let active_topic_style =
    "span[data-topic=\"" <> topic_id <> "\"] { text-decoration: underline; }"

  // Extract ancestors and descendants from metadata
  let #(ancestor_ids, descendant_ids, relative_ids) = case metadata {
    Ok(audit_data.NamedTopic(ancestors:, descendants:, expanded_references:, ..)) -> {
      let ancestor_id_list = list.map(ancestors, fn(t) { t.id })
      let descendant_id_list = list.map(descendants, fn(t) { t.id })
      let relative_id_list = flatten_expanded_references(expanded_references)
      #(ancestor_id_list, descendant_id_list, relative_id_list)
    }
    _ -> #([], [], [])
  }

  // Build styles for ancestors (wavy underline in ancestor color)
  let ancestor_styles =
    list.map(ancestor_ids, fn(id) {
      dromel.selector(expanded_references_panel_id)
      <> " span[data-topic=\""
      <> id
      <> "\"] { text-decoration: underline; }"
    })
    |> string.join("\n")

  // Build styles for descendants (wavy underline in descendant color)
  let descendant_styles =
    list.map(descendant_ids, fn(id) {
      dromel.selector(expanded_references_panel_id)
      <> " span[data-topic=\""
      <> id
      <> "\"] { text-decoration: underline; }"
    })
    |> string.join("\n")

  // Build styles for relatives (wavy underline in relative color)
  let relative_styles =
    list.map(relative_ids, fn(id) {
      dromel.selector(expanded_references_panel_id)
      <> " span[data-topic=\""
      <> id
      <> "\"] { text-decoration: underline; }"
    })
    |> string.join("\n")

  // Combine all styles (active topic style comes last to take precedence)
  let style_content =
    string.join(
      [relative_styles, ancestor_styles, descendant_styles, active_topic_style],
      "\n",
    )

  let style_id = dromel.Id(active_topic_style_id)

  // Try to find existing style element
  case dromel.query_document(style_id) {
    Ok(style_element) -> {
      let _ = dromel.set_inner_text(style_element, style_content)
      Nil
    }
    Error(Nil) -> {
      // Create new style element and append to app element
      let style_element =
        dromel.new("style")
        |> dromel.set_id(style_id)
        |> dromel.set_inner_text(style_content)
      let _ = audit_data.app_element() |> dromel.append_child(style_element)
      Nil
    }
  }
}

fn get_active_topic_view(container: element.Element) -> Result(TopicView, Nil) {
  dromel.get_data(container, active_topic_view_key)
  |> result.try(get_topic_view)
}

const current_mentions_index_key = dromel.DataKey("current_mentions_index")

const current_child_topic_index_key = dromel.DataKey(
  "current_child_topic_index",
)

const current_comments_index_key = dromel.DataKey("current_comments_index")

const current_references_index_key = dromel.DataKey("current_references_index")

const active_panel_key = dromel.DataKey("active_panel")

const topic_key = dromel.DataKey("topic")

const member_key = dromel.DataKey("member")

const contract_key = dromel.DataKey("contract")

fn set_current_mentions_index(container: element.Element, index: Int) -> Nil {
  let _ =
    dromel.set_data(container, current_mentions_index_key, int.to_string(index))
  Nil
}

fn get_current_mentions_index(container: element.Element) -> Int {
  dromel.get_data(container, current_mentions_index_key)
  |> result.try(int.parse)
  |> result.unwrap(0)
}

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

fn set_current_references_index(container: element.Element, index: Int) -> Nil {
  let _ =
    dromel.set_data(
      container,
      current_references_index_key,
      int.to_string(index),
    )
  Nil
}

fn get_current_references_index(container: element.Element) -> Int {
  dromel.get_data(container, current_references_index_key)
  |> result.try(int.parse)
  |> result.unwrap(0)
}

fn set_current_comments_index(container: element.Element, index: Int) -> Nil {
  let _ =
    dromel.set_data(container, current_comments_index_key, int.to_string(index))
  Nil
}

fn get_current_comments_index(container: element.Element) -> Int {
  dromel.get_data(container, current_comments_index_key)
  |> result.try(int.parse)
  |> result.unwrap(0)
}

fn set_active_panel(container: element.Element, panel: ActivePanel) -> Nil {
  dromel.set_data(
    container,
    active_panel_key,
    history_graph.active_panel_to_string(panel),
  )
  Nil
}

fn get_active_panel(container: element.Element) -> ActivePanel {
  use Ok(data) <- case dromel.get_data(container, active_panel_key) {
    Error(Nil) -> history_graph.TopicPanel
  }
  use Ok(panel) <- case history_graph.active_panel_from_string(data) {
    Error(snag) -> {
      log.print_error(snag)
      history_graph.TopicPanel
    }
  }
  panel
}

fn get_current_focus_state(
  container: element.Element,
) -> history_graph.FocusState {
  history_graph.FocusState(
    mentions_index: get_current_mentions_index(container),
    comments_index: get_current_comments_index(container),
    topic_index: get_current_child_topic_index(container),
    references_index: get_current_references_index(container),
    active_panel: get_active_panel(container),
  )
}

fn set_focus_state(
  container: element.Element,
  focus_state: history_graph.FocusState,
) -> Nil {
  set_current_mentions_index(container, focus_state.mentions_index)
  set_current_comments_index(container, focus_state.comments_index)
  set_current_child_topic_index(container, focus_state.topic_index)
  set_current_references_index(container, focus_state.references_index)
  set_active_panel(container, focus_state.active_panel)
}

// ============================================================================
// View Mounting and Removal
// ============================================================================

// 40ch for the source width, 1rem for the padding widths, 2px for the borders wid
const container_style = "position: relative; padding-top: 0.5rem; width: calc(40ch + 1rem + 2px);"

const panel_style = "min-height: 0; height: 100%; width: unset;"

const single_panel_style = "border-radius: 8px; border: 1px solid var(--color-body-border); padding: 0.5rem; background: var(--color-code-bg); margin-bottom: 0.5rem;"

// Note: These styles use border-width and border-style separately from border-color
// so that the out-of-scope border-color (--color-body-out-of-scope-bg) is not overridden
const combined_panel_first_style = "border-top-width: 1px; border-top-style: solid; border-top-right-radius: 8px; border-top-left-radius: 8px;"

const combined_panel_last_style = "border-bottom-right-radius: 8px; border-bottom-left-radius: 8px; border-bottom-width: 1px; border-bottom-style: solid;"

const combined_panel_style = "border-color: var(--color-body-border); border-right-width: 1px; border-right-style: solid; border-left-width: 1px; border-left-style: solid; border-bottom-width: 1px; border-bottom-style: dashed; padding: 0.5rem; background: var(--color-code-bg); max-height: 100%;"

const combined_panel_member_title_style = "outline: 1px solid var(--color-body-border); border-radius: 4px; margin-bottom: 0.5rem; background: var(--color-body-bg); padding-left: 0.5rem;"

const scope_style = "position: relative; display: inline-flex; align-items: center; gap: 0.25rem; margin-bottom: 0.5rem; padding-right: 0.5rem; direction: rtl; overflow: hidden;"

const scope_standard_class = dromel.Class("scope-standard")

const scope_expanded_class = dromel.Class("scope-expanded")

const reference_group_class = dromel.Class("reference-group")

const scope_overflow_gradient_style_hidden = "display: none;"

const scope_overflow_gradient_style_visible = "position: absolute; left: 0; top: 0; bottom: 0; width: 1.5rem; background: linear-gradient(to right, var(--color-body-bg), transparent); pointer-events: none;"

const footer_style = "position: absolute; bottom: 0.25rem; right: 0.5rem;"

fn parse_comment_type(content: String) -> #(audit_data.CommentType, String) {
  let #(type_, rest) = case string.trim_start(content) {
    "/note " <> rest -> #(audit_data.Note, rest)
    "/i " <> rest -> #(audit_data.Info, rest)
    "/info " <> rest -> #(audit_data.Info, rest)
    "/q " <> rest -> #(audit_data.Question, rest)
    "/question " <> rest -> #(audit_data.Question, rest)
    "/a " <> rest -> #(audit_data.Answer, rest)
    "/answer " <> rest -> #(audit_data.Answer, rest)
    "/t " <> rest -> #(audit_data.Todo, rest)
    "/todo " <> rest -> #(audit_data.Todo, rest)
    "/f " <> rest -> #(audit_data.FindingLead, rest)
    "/finding " <> rest -> #(audit_data.FindingLead, rest)
    _ -> #(audit_data.Note, content)
  }
  #(type_, string.trim_start(rest))
}

const label_visible_style = "position: absolute; top: 0; left: 0.5rem; font-size: 0.7rem; color: var(--color-body-text); background: var(--color-body-bg); padding: 0 0.25rem; z-index: 1;"

fn update_comment_type_label(e: event.Event(a), label: element.Element) -> Nil {
  case dromel.cast(event.target(e)) {
    Ok(input_elem) -> {
      case dromel.value(input_elem) {
        Ok(content) -> {
          let #(comment_type, _) = parse_comment_type(content)
          case comment_type {
            audit_data.Note -> {
              dromel.set_style(label, "display: none;")
              Nil
            }
            _ -> {
              dromel.set_inner_text(
                label,
                audit_data.comment_type_to_string(comment_type),
              )
              dromel.set_style(label, label_visible_style)
              Nil
            }
          }
        }
        _ -> Nil
      }
    }
    Error(_) -> Nil
  }
}

fn mount_topic_view(container: element.Element) -> ActiveViewElements {
  // Create the mentions panel element
  let mentions_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let mentions_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Mentions")
    |> dromel.set_style(footer_style)

  let mentions_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(mentions_footer)
    |> dromel.append_child(mentions_panel)

  // Create the comments panel element
  let comments_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let comment_type_label =
    dromel.new_span()
    |> dromel.add_class(elements.code_style_class)

  let comments_input =
    dromel.new_input()
    |> dromel.set_type("text")
    |> dromel.set_placeholder("Add a comment...")
    |> dromel.set_style(
      "width: 100%; padding: 0.5rem; background: var(--color-body-bg); color: var(--color-body-text); border: none; border-bottom: 1px solid var(--color-body-border); font-size: 14px; box-sizing: border-box;",
    )
    |> dromel.add_event_listener("keydown", fn(e) {
      case event.key(e) {
        "Enter" -> {
          event.prevent_default(e)
          case dromel.cast(event.target(e)) {
            Ok(input_elem) -> {
              case dromel.value(input_elem) {
                Ok(content) if content != "" -> {
                  case get_active_topic_view(container) {
                    Ok(active_view) -> {
                      let #(comment_type, comment_content) =
                        parse_comment_type(content)
                      let _ =
                        dromel.set_attribute(input_elem, "disabled", "true")
                      audit_data.create_comment(
                        active_view.topic_id,
                        comment_content,
                        0,
                        comment_type,
                        fn(result) {
                          case result {
                            Ok(_) -> {
                              dromel.set_value(input_elem, "")
                              dromel.remove_attribute(input_elem, "disabled")
                              dromel.set_style(
                                comment_type_label,
                                "display: none;",
                              )
                              dromel.blur(input_elem)
                              case get_active_panel(container) {
                                history_graph.MentionsPanel ->
                                  move_to_mention_child(container, 0)
                                history_graph.CommentsPanel ->
                                  move_to_comment_child(container, 0)
                                history_graph.TopicPanel ->
                                  move_to_topic_child(container, 0)
                                history_graph.ReferencesPanel ->
                                  move_to_reference_child(container, 0)
                              }
                            }
                            Error(error) -> {
                              let _ =
                                dromel.remove_attribute(input_elem, "disabled")
                              snag.layer(error, "Failed to create comment")
                              |> snag.line_print
                              |> io.println_error
                            }
                          }
                        },
                      )
                      Nil
                    }
                    Error(Nil) -> Nil
                  }
                }
                _ -> Nil
              }
            }
            Error(_) -> Nil
          }
        }
        "Escape" -> {
          event.prevent_default(e)
          case dromel.cast(event.target(e)) {
            Ok(input_elem) -> {
              dromel.blur(input_elem)
              case get_active_panel(container) {
                history_graph.MentionsPanel ->
                  move_to_mention_child(container, 0)
                history_graph.CommentsPanel ->
                  move_to_comment_child(container, 0)
                history_graph.TopicPanel -> move_to_topic_child(container, 0)
                history_graph.ReferencesPanel ->
                  move_to_reference_child(container, 0)
              }
            }
            Error(_) -> Nil
          }
        }
        _ -> Nil
      }
    })
    |> dromel.add_event_listener("focus", fn(e) {
      context.add_context(context.Input)
      update_comment_type_label(e, comment_type_label)
    })
    |> dromel.add_event_listener("blur", fn(_e) {
      context.remove_context(context.Input)
      dromel.set_style(comment_type_label, "display: none;")
      Nil
    })
    |> dromel.add_event_listener("input", fn(e) {
      update_comment_type_label(e, comment_type_label)
    })

  let comments_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Comments")
    |> dromel.set_style(footer_style)

  let comments_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(comments_footer)
    |> dromel.append_child(comment_type_label)
    |> dromel.append_child(comments_input)
    |> dromel.append_child(comments_panel)

  // Create the topic panel element
  let topic_panel =
    dromel.new_div()
    |> dromel.set_id(topic_panel_id)
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let topic_footer =
    dromel.new_div()
    |> dromel.set_style(footer_style)
    |> dromel.set_inner_text("Current Topic")

  let topic_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(topic_panel)
    |> dromel.append_child(topic_footer)

  // Create the expanded references panel element
  let expanded_references_panel =
    dromel.new_div()
    |> dromel.set_id(expanded_references_panel_id)
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let expanded_references_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Expanded References")
    |> dromel.set_style(footer_style)

  let expanded_references_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(expanded_references_footer)
    |> dromel.append_child(expanded_references_panel)

  let _ = container |> dromel.append_child(mentions_container)
  let _ = container |> dromel.append_child(comments_container)
  let _ = container |> dromel.append_child(topic_container)
  let _ = container |> dromel.append_child(expanded_references_container)

  let elements =
    ActiveViewElements(
      mentions_panel:,
      mentions_container:,
      comments_panel:,
      comments_container:,
      comments_input:,
      topic_panel:,
      topic_container:,
      expanded_references_panel:,
      expanded_references_container:,
      mentions_tokens: array.from_list([]),
      comments_tokens: array.from_list([]),
      topic_children_tokens: array.from_list([]),
      expanded_references_tokens: array.from_list([]),
    )

  set_active_view_elements(elements)

  elements
}

/// Save scroll position and remove DOM elements for the active view
/// Save scroll position and reset DOM elements for reuse (avoids flickering)
/// Returns the existing elements with their content cleared
fn reset_active_view() -> Result(ActiveViewElements, Nil) {
  case get_active_view_elements() {
    Ok(elements) -> {
      // Clear inner HTML of panels and reset scroll positions
      let _ = dromel.set_inner_html(elements.mentions_panel, "")
      dromel.set_scroll_top(elements.mentions_panel, 0.0)

      let _ = dromel.set_inner_html(elements.comments_panel, "")
      dromel.set_scroll_top(elements.comments_panel, 0.0)

      let _ = dromel.set_inner_html(elements.topic_panel, "")
      // Reset the topic panel style to default (removes out-of-scope border color)
      let _ = dromel.set_style(elements.topic_panel, panel_style)
      // Remove data attributes from previous view
      let _ = dromel.remove_data(elements.topic_panel, topic_key)
      let _ = dromel.remove_data(elements.topic_panel, member_key)
      let _ = dromel.remove_data(elements.topic_panel, contract_key)
      dromel.set_scroll_top(elements.topic_panel, 0.0)

      let _ = dromel.set_inner_html(elements.expanded_references_panel, "")
      dromel.set_scroll_top(elements.expanded_references_panel, 0.0)

      // Reset the token arrays since content was cleared
      let reset_elements =
        ActiveViewElements(
          ..elements,
          mentions_tokens: array.from_list([]),
          comments_tokens: array.from_list([]),
          topic_children_tokens: array.from_list([]),
          expanded_references_tokens: array.from_list([]),
        )
      set_active_view_elements(reset_elements)

      Ok(reset_elements)
    }
    _ -> Error(Nil)
  }
}

// ============================================================================
// Source Text Loading Callbacks
// ============================================================================

/// Helper to apply first/last styling to reference source elements
fn apply_first_last_style(
  reference_source: element.Element,
  index: Int,
  total: Int,
) -> Nil {
  // Apply first style if this is the first element
  case index {
    0 -> {
      dromel.add_style(reference_source, combined_panel_first_style)
      Nil
    }
    _ -> Nil
  }
  // Apply last style if this is the last element (can be both first and last)
  case index == total - 1 {
    True -> {
      dromel.add_style(reference_source, combined_panel_last_style)
      Nil
    }
    False -> Nil
  }
}

/// Reapply first/last styles to all source containers in a reference group
fn reapply_first_last_styles(group_container: element.Element) -> Nil {
  let all_containers =
    dromel.query_element_all(group_container, elements.source_container_class)

  let total = array.size(all_containers)

  all_containers
  |> array.to_list
  |> list.index_map(fn(elem, index) {
    apply_first_last_style(elem, index, total)
  })

  Nil
}

/// Helper to populate a reference source element with source text or error
fn inject_inline_info_comments(container: element.Element) -> Nil {
  echo "injecting info comments"
  let placeholders =
    dromel.query_element_all(container, elements.placeholder_topic_sel)
    |> array.to_list

  list.each(placeholders, fn(placeholder) {
    case
      dromel.get_data(placeholder, elements.placeholder_topic_key)
      |> echo as "topic id"
    {
      Ok(topic_id) -> {
        audit_data.with_topic_info_comments(topic_id, fn(result) {
          case result |> echo as "topic ids" {
            Ok(info_comment_ids) ->
              list.each(info_comment_ids, fn(comment_topic_id) {
                audit_data.with_source_text(
                  audit_data.Topic(id: comment_topic_id),
                  fn(source_text_result) {
                    case source_text_result {
                      Ok(source_text) -> {
                        echo "got source text for topic "
                          <> comment_topic_id
                          <> ": "
                          <> source_text
                        dromel.new_div()
                        |> dromel.set_class(elements.inline_comment_class)
                        |> dromel.add_class(elements.code_style_class)
                        |> dromel.set_inner_html(source_text)
                        |> dromel.append_as_child(to: placeholder)
                        Nil
                      }
                      Error(error) -> {
                        error
                        |> snag.layer(
                          "Unable to fetch inline info comment source text for "
                          <> comment_topic_id,
                        )
                        |> log.print_error
                        Nil
                      }
                    }
                  },
                )
              })
            Error(error) -> {
              error
              |> snag.layer(
                "Unable to fetch info comments for topic " <> topic_id,
              )
              |> log.print_error
              Nil
            }
          }
        })
      }
      Error(Nil) -> {
        snag.new("Missing data-placeholder-topic value on placeholder element")
        |> log.print_error
        Nil
      }
    }
  })
}

fn populate_reference_source(
  ref_entry: audit_data.ReferenceEntry,
  reference_source: element.Element,
  source_text: Result(String, snag.Snag),
) -> Nil {
  case source_text {
    Ok(source_text) -> {
      case ref_entry {
        audit_data.ProjectReference(..) -> {
          let source_div =
            dromel.new_div()
            |> dromel.set_inner_html(source_text)
            |> dromel.append_as_child(to: reference_source)
          inject_inline_info_comments(source_div)
          Nil
        }
        audit_data.ProjectReferenceWithMentions(mention_topics:, ..)
        | audit_data.CommentMention(mention_topics:, ..) -> {
          let comments = dromel.new_div()

          list.each(mention_topics, fn(mention_topic) {
            let comment_placeholder =
              dromel.new_div()
              |> dromel.set_style(
                // "outline: 1px solid var(--color-body-border); border-radius: 4px; margin-bottom: 0.5rem; padding-left: 0.5rem;",
                // "margin-bottom: 0.5rem;",
                "",
              )
              |> dromel.set_class(elements.inline_comment_class)
              |> dromel.add_class(elements.code_style_class)
              |> dromel.append_as_child(to: comments)

            audit_data.with_source_text(mention_topic, fn(comment_source_text) {
              case comment_source_text {
                Ok(text) -> {
                  dromel.new_div()
                  |> dromel.set_inner_html(text)
                  |> dromel.append_as_child(to: comment_placeholder)
                  Nil
                }
                Error(error) -> {
                  dromel.new_div()
                  |> dromel.set_inner_html(log.render_source_error(error))
                  |> dromel.append_as_child(to: comment_placeholder)
                  Nil
                }
              }
            })
          })

          comments
          |> dromel.append_as_child(to: reference_source)

          dromel.new_div()
          |> dromel.set_inner_html(source_text)
          |> dromel.append_as_child(to: reference_source)
          Nil
        }
      }
    }
    Error(error) -> {
      let _ =
        dromel.new_div()
        |> dromel.set_inner_html(log.render_source_error(error))
        |> dromel.append_as_child(to: reference_source)

      Nil
    }
  }
}

/// Generic function to populate a panel with grouped source containers
fn populate_grouped_source_panel(
  config: GroupedSourcePanelConfig,
  groups: List(audit_data.ReferenceGroup),
) -> Nil {
  list.each(groups, fn(ref_group) {
    let group_container =
      dromel.new_div()
      |> dromel.set_style("margin-bottom: 0.5rem;")
      |> dromel.set_class(reference_group_class)
      |> dromel.append_as_child(to: config.panel)

    // Mount the contract breadcrumb once per reference group
    let contract_scope =
      dromel.new_div()
      |> dromel.set_class(reference_title_class)
      |> dromel.set_style(scope_style)
      |> dromel.add_class(scope_standard_class)
      |> dromel.append_as_child(to: group_container)

    mount_breadcrumb_parts(contract_scope, [TopicPart(ref_group.scope)])

    // Calculate total reference count for first/last styling
    let total_references =
      list.length(ref_group.scope_references)
      + list.fold(ref_group.nested_references, 0, fn(acc, nested_group) {
        acc + list.length(nested_group.references)
      })

    // Render scope-level references
    let index_after_scope =
      list.index_fold(ref_group.scope_references, 0, fn(index, ref_entry, _) {
        let source_placeholder =
          dromel.new_div()
          |> dromel.append_as_child(to: group_container)

        audit_data.with_topic_data(
          ref_entry.reference_topic,
          fn(_metadata, source_text, _comments) {
            let reference_source =
              dromel.new_div()
              |> dromel.add_class(elements.source_container_class)
              |> dromel.set_data(topic_key, ref_entry.reference_topic.id)
              |> dromel.set_data(contract_key, ref_group.scope.id)
              |> dromel.set_style(combined_panel_style)
              |> dromel.add_style("padding-left: 0.5rem;")

            // Apply out-of-scope border color if scope is not in scope
            case ref_group.is_in_scope {
              True -> Nil
              False -> {
                dromel.add_style(
                  reference_source,
                  "border-color: var(--color-body-out-of-scope-bg)",
                )
                Nil
              }
            }

            apply_first_last_style(reference_source, index, total_references)
            populate_reference_source(ref_entry, reference_source, source_text)

            let _ =
              source_placeholder
              |> dromel.append_child(reference_source)

            // Re-gather tokens after each source loads
            gather_panel_tokens(config)

            Nil
          },
        )

        index + 1
      })

    // Render nested-level references, grouped by subscope
    list.fold(
      ref_group.nested_references,
      index_after_scope,
      fn(current_index, nested_group) {
        // Track whether this is the first reference in the nested group
        list.index_fold(
          nested_group.references,
          current_index,
          fn(index, ref_entry, nested_ref_index) {
            let source_placeholder =
              dromel.new_div()
              |> dromel.append_as_child(to: group_container)

            audit_data.with_topic_data(
              ref_entry.reference_topic,
              fn(_metadata, source_text, _comments) {
                let reference_source =
                  dromel.new_div()
                  |> dromel.add_class(elements.source_container_class)
                  |> dromel.set_data(topic_key, ref_entry.reference_topic.id)
                  |> dromel.set_data(member_key, nested_group.subscope.id)
                  |> dromel.set_data(contract_key, ref_group.scope.id)
                  |> dromel.set_style(combined_panel_style)
                  |> dromel.add_style("padding-left: 0.5rem;")

                // Apply out-of-scope border color if contract is not in scope
                case ref_group.is_in_scope {
                  True -> Nil
                  False -> {
                    dromel.add_style(
                      reference_source,
                      "border-color: var(--color-body-out-of-scope-bg)",
                    )
                    Nil
                  }
                }

                apply_first_last_style(
                  reference_source,
                  index,
                  total_references,
                )

                // Add subscope title only for the first reference in the nested group
                case nested_ref_index {
                  0 -> {
                    let subscope_title =
                      dromel.new_div()
                      |> dromel.set_style(combined_panel_member_title_style)
                      |> dromel.set_inner_html("...")
                      |> dromel.append_as_child(to: reference_source)

                    audit_data.with_topic_metadata(
                      nested_group.subscope,
                      fn(metadata: Result(audit_data.TopicMetadata, snag.Snag)) -> Nil {
                        case metadata {
                          Ok(metadata) -> {
                            subscope_title
                            |> dromel.set_inner_html(
                              audit_data.topic_metadata_highlighted_name(
                                metadata,
                              ),
                            )
                            Nil
                          }
                          Error(snag) -> {
                            subscope_title
                            |> dromel.set_inner_html(snag.line_print(snag))
                            Nil
                          }
                        }
                      },
                    )
                    Nil
                  }
                  _ -> Nil
                }

                populate_reference_source(
                  ref_entry,
                  reference_source,
                  source_text,
                )

                let _ =
                  source_placeholder
                  |> dromel.append_child(reference_source)

                // Re-gather tokens after each source loads
                gather_panel_tokens(config)

                Nil
              },
            )

            index + 1
          },
        )
      },
    )
  })
}

/// Gather topic tokens for a panel based on its configuration
fn gather_panel_tokens(config: GroupedSourcePanelConfig) -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens =
        dromel.query_element_all(config.panel, elements.topic_tokens_class)
      let active_panel = get_active_panel(config.container)
      case config.token_field {
        MentionsPanelTokens -> {
          set_active_view_elements(
            ActiveViewElements(..active_elements, mentions_tokens: tokens),
          )
          // Only focus if this is the active panel
          case active_panel {
            history_graph.MentionsPanel -> {
              let index = get_current_mentions_index(config.container)
              case array.get(tokens, index) {
                Ok(el) -> focus_topic_token_and_prefetch(el)
                Error(Nil) -> Nil
              }
            }
            history_graph.CommentsPanel
            | history_graph.TopicPanel
            | history_graph.ReferencesPanel -> Nil
          }
        }
        CommentsPanelTokens -> {
          set_active_view_elements(
            ActiveViewElements(..active_elements, comments_tokens: tokens),
          )
          case active_panel {
            history_graph.CommentsPanel -> {
              let index = get_current_comments_index(config.container)
              case array.get(tokens, index) {
                Ok(el) -> focus_topic_token_and_prefetch(el)
                Error(Nil) -> Nil
              }
            }
            history_graph.MentionsPanel
            | history_graph.TopicPanel
            | history_graph.ReferencesPanel -> Nil
          }
        }
        TopicPanelTokens -> {
          set_active_view_elements(
            ActiveViewElements(..active_elements, topic_children_tokens: tokens),
          )
          // Only focus if this is the active panel. Without this check,
          // navigating back to a topic where the user was in the references
          // panel would incorrectly focus the topic panel, because
          // populate_topic_panel runs before populate_expanded_references_panel.
          case active_panel {
            history_graph.TopicPanel -> {
              let index = get_current_child_topic_index(config.container)
              case array.get(tokens, index) {
                Ok(el) -> focus_topic_token_and_prefetch(el)
                Error(Nil) -> Nil
              }
            }
            history_graph.MentionsPanel
            | history_graph.CommentsPanel
            | history_graph.ReferencesPanel -> Nil
          }
        }
        ReferencesPanelTokens -> {
          set_active_view_elements(
            ActiveViewElements(
              ..active_elements,
              expanded_references_tokens: tokens,
            ),
          )
          // Only focus if this is the active panel (see comment above)
          case active_panel {
            history_graph.ReferencesPanel -> {
              let index = get_current_references_index(config.container)
              case array.get(tokens, index) {
                Ok(el) -> focus_topic_token_and_prefetch(el)
                Error(Nil) -> Nil
              }
            }
            history_graph.MentionsPanel
            | history_graph.CommentsPanel
            | history_graph.TopicPanel -> Nil
          }
        }
      }
      Nil
    }
    Error(Nil) -> Nil
  }
}

/// Callback for loading topic metadata and populating the topic panel
fn populate_topic_panel(
  container: element.Element,
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
  elements: ActiveViewElements,
) -> Nil {
  case metadata {
    Ok(audit_data.NamedTopic(references:, ..)) -> {
      // Clear the topic panel and use grouped source panel rendering
      let _ = dromel.set_inner_html(elements.topic_panel, "")

      populate_grouped_source_panel(
        GroupedSourcePanelConfig(
          container:,
          panel: elements.topic_panel,
          token_field: TopicPanelTokens,
        ),
        references,
      )
    }
    Ok(metadata) -> {
      let parts = case metadata {
        audit_data.UnnamedTopic(kind:, scope:, ..) ->
          get_unnamed_topic_scope_parts(scope, kind)
        audit_data.TitledTopic(title:, ..) -> {
          [TextPart(title)]
        }
        audit_data.NamedTopic(..) -> panic as "unreachable"
        audit_data.CommentTopic(..) -> [TextPart("Comment")]
      }

      // For unnamed topics, directly render the topic's source text
      audit_data.with_source_text(metadata.topic, fn(source_text) {
        case source_text {
          Ok(source_text) -> {
            let topic_title =
              dromel.new_div()
              |> dromel.set_style(
                "padding-left: 0.5rem; margin-bottom: 0.5rem;",
              )

            mount_breadcrumb_parts(parts, to: topic_title)

            let source_panel =
              dromel.new_div()
              |> dromel.set_style(single_panel_style)
              |> dromel.set_inner_html(source_text)

            inject_inline_info_comments(source_panel)

            elements.topic_panel
            |> dromel.append_child(topic_title)
            |> dromel.append_child(source_panel)

            // Gather tokens after source loads
            gather_panel_tokens(GroupedSourcePanelConfig(
              container:,
              panel: elements.topic_panel,
              token_field: TopicPanelTokens,
            ))

            Nil
          }
          Error(error) -> {
            elements.topic_panel
            |> dromel.set_inner_html(log.render_source_error(error))
            Nil
          }
        }
      })
    }
    Error(snag) -> {
      elements.topic_panel
      |> dromel.set_inner_html(log.render_source_error(snag))
      Nil
    }
  }
}

/// Callback for loading topic metadata and populating the expanded references panel
fn populate_expanded_references_panel(
  container: element.Element,
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
  elements: ActiveViewElements,
) -> Nil {
  case metadata {
    Ok(metadata) -> {
      let expanded_references = case metadata {
        audit_data.NamedTopic(expanded_references:, ..) -> expanded_references
        _ -> []
      }

      populate_grouped_source_panel(
        GroupedSourcePanelConfig(
          container:,
          panel: elements.expanded_references_panel,
          token_field: ReferencesPanelTokens,
        ),
        expanded_references,
      )
    }
    Error(_snag) -> {
      let _ =
        elements.expanded_references_panel
        |> dromel.set_inner_html(
          "<div style='color: var(--color-body-text); font-size: 0.9rem;'>Unable to load expanded references</div>",
        )
      Nil
    }
  }
}

/// Callback for loading topic metadata and populating the mentions panel
fn populate_mentions_panel(
  container: element.Element,
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
  elements: ActiveViewElements,
) -> Nil {
  case metadata {
    Ok(metadata) -> {
      let mentions = case metadata {
        audit_data.NamedTopic(mentions:, ..) -> mentions
        _ -> []
      }

      populate_grouped_source_panel(
        GroupedSourcePanelConfig(
          container:,
          panel: elements.mentions_panel,
          token_field: MentionsPanelTokens,
        ),
        mentions,
      )
    }
    Error(_snag) -> {
      let _ =
        elements.mentions_panel
        |> dromel.set_inner_html(
          "<div style='color: var(--color-body-text); font-size: 0.9rem;'>Unable to load mentions</div>",
        )
      Nil
    }
  }
}

/// Populate the comments panel with comments for the given topic
fn populate_comments_panel(
  container: element.Element,
  topic_id: String,
  elements: ActiveViewElements,
) -> Nil {
  let config =
    GroupedSourcePanelConfig(
      container:,
      panel: elements.comments_panel,
      token_field: CommentsPanelTokens,
    )
  audit_data.with_topic_comments(topic_id, fn(comments_result) {
    case comments_result {
      Ok(comment_entries) -> {
        list.index_fold(comment_entries, 0, fn(index, entry, _) {
          let comment_topic = audit_data.Topic(id: entry.comment_topic_id)
          let source_placeholder =
            dromel.new_div()
            |> dromel.append_as_child(to: elements.comments_panel)

          audit_data.with_topic_data(
            comment_topic,
            fn(_metadata, source_text, _comments) {
              let comment_source =
                dromel.new_div()
                |> dromel.add_class(elements.source_container_class)
                |> dromel.set_data(topic_key, entry.comment_topic_id)
                |> dromel.set_style(single_panel_style)

              case source_text {
                Ok(source_text) -> {
                  dromel.new_div()
                  |> dromel.set_inner_html(source_text)
                  |> dromel.append_as_child(to: comment_source)
                  Nil
                }
                Error(error) -> {
                  dromel.new_div()
                  |> dromel.set_inner_html(log.render_source_error(error))
                  |> dromel.append_as_child(to: comment_source)
                  Nil
                }
              }

              let _ =
                source_placeholder
                |> dromel.append_child(comment_source)

              gather_panel_tokens(config)

              Nil
            },
          )

          index + 1
        })
        Nil
      }
      Error(_snag) -> {
        let _ =
          elements.comments_panel
          |> dromel.set_inner_html(
            "<div style='color: var(--color-body-text); font-size: 0.9rem;'>Unable to load comments</div>",
          )
        Nil
      }
    }
  })
}

// ============================================================================
// Topic Scope Breadcrumb
// ============================================================================

const scope_item_style = "color: var(--color-body-text); white-space: nowrap;"

const scope_chevron_style = "display: inline-flex; align-items: center; opacity: 0.6; width: 0.75em; height: 0.75em; line-height: 1; flex-shrink: 0;"

/// A part of a breadcrumb - either a file name string or a topic
type BreadcrumbPart {
  // For file names and other prefixes like "global"
  TextPart(String)
  TopicPart(audit_data.Topic)
}

fn get_fully_qualified_name_parts(
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
) {
  case metadata {
    Ok(metadata) ->
      case metadata.scope {
        audit_data.Global -> [TextPart("global"), TopicPart(metadata.topic)]
        audit_data.Container(container:) -> [
          TextPart(container),
          TopicPart(metadata.topic),
        ]
        audit_data.Component(container:, component:) -> [
          TextPart(container),
          TopicPart(component),
          TopicPart(metadata.topic),
        ]
        audit_data.Member(container:, component:, member:)
        | audit_data.SemanticBlock(container:, component:, member:, ..) -> [
          TextPart(container),
          TopicPart(component),
          TopicPart(member),
          TopicPart(metadata.topic),
        ]
      }
    Error(_snag) -> [TextPart("Unknown")]
  }
}

fn get_unnamed_topic_scope_parts(
  scope: audit_data.Scope,
  kind: audit_data.UnnamedTopicKind,
) {
  case kind {
    // For documentation unnamed topics with Container scope, show the
    // container path as the scope
    audit_data.DocumentationBlockQuote
    | audit_data.DocumentationCodeBlock
    | audit_data.DocumentationHeading
    | audit_data.DocumentationList
    | audit_data.DocumentationParagraph
    | audit_data.DocumentationRoot
    | audit_data.DocumentationSentence -> [
      case scope {
        audit_data.Global -> TextPart("global")
        audit_data.Container(container:) -> TextPart(container)
        audit_data.Component(component:, ..)
        | audit_data.Member(component:, ..)
        | audit_data.SemanticBlock(component:, ..) -> TopicPart(component)
      },
    ]
    _ ->
      case scope {
        audit_data.Global -> [TextPart("global")]
        audit_data.Container(container:) -> [TextPart(container)]
        audit_data.Component(component:, ..)
        | audit_data.Member(component:, ..)
        | audit_data.SemanticBlock(component:, ..) -> [
          TopicPart(component),
        ]
      }
  }
}

/// Render breadcrumb parts into a container element
/// Creates breadcrumb elements separated by chevron_right icons
/// Parts should be in display order (will be reversed for RTL container)
fn mount_breadcrumb_parts(
  to container: element.Element,
  parts parts: List(BreadcrumbPart),
) -> Nil {
  // Clear current container content to save a clear slate to insert new
  // breadcrumb elements to
  dromel.set_inner_html(container, "")

  // Create gradient overlay element (hidden by default, shown when overflowing)
  let gradient =
    dromel.new_div()
    |> dromel.set_style(scope_overflow_gradient_style_hidden)
    |> dromel.append_as_child(to: container)

  // Reverse because container has direction: rtl, so last items appear first (rightmost)
  let reversed_parts = list.reverse(parts)

  // Create breadcrumb elements for each part
  list.index_map(reversed_parts, fn(part, index) {
    // Add chevron delimiter before each item except the first
    case index > 0 {
      True -> {
        let _ =
          dromel.new_span()
          |> dromel.set_inner_html(icons.chevron_right_breadcrumb)
          |> dromel.set_style(scope_chevron_style)
          |> dromel.append_as_child(to: container)
        Nil
      }
      False -> Nil
    }

    case part {
      TextPart(name) -> {
        let _ =
          dromel.new("code")
          |> dromel.set_inner_text(name)
          |> dromel.set_style(scope_item_style)
          |> dromel.append_as_child(to: container)
        Nil
      }
      TopicPart(topic) -> {
        let text_span =
          dromel.new_span()
          |> dromel.set_inner_text("...")
          |> dromel.set_style(scope_item_style)
        let _ = dromel.append_child(container, text_span)

        audit_data.with_topic_metadata(topic, fn(result) {
          case result {
            Ok(topic_metadata) -> {
              let name =
                audit_data.topic_metadata_highlighted_name(topic_metadata)
              let _ = dromel.set_inner_html(text_span, name)
              // Check for overflow after content is loaded and show gradient if needed
              case
                dromel.scroll_width(container) > dromel.client_width(container)
              {
                True -> {
                  container
                  |> dromel.remove_class(scope_standard_class)
                  |> dromel.add_class(scope_expanded_class)
                  dromel.set_style(
                    gradient,
                    scope_overflow_gradient_style_visible,
                  )
                  Nil
                }
                False -> Nil
              }
              Nil
            }
            Error(_) -> {
              dromel.set_inner_text(text_span, "?")
              Nil
            }
          }
        })
      }
    }
  })

  Nil
}

// ============================================================================
// Public API
// ============================================================================

fn repopulate_view(
  container: element.Element,
  view: TopicView,
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
) -> Nil {
  let elements = case reset_active_view() {
    Ok(elements) -> elements
    Error(Nil) -> mount_topic_view(container)
  }

  set_active_topic_view(container, view, metadata)

  get_fully_qualified_name_parts(metadata)
  |> mount_breadcrumb_parts(to: get_history_container())

  populate_topic_panel(container, metadata, elements)
  populate_expanded_references_panel(container, metadata, elements)
  populate_mentions_panel(container, metadata, elements)
  populate_comments_panel(container, view.topic_id, elements)
}

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
          case
            history_graph.go_to_new_entry(
              active_view.entry_id,
              get_current_focus_state(container),
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

      // Update the URL to reflect the active topic
      update_url_for_topic(new_entry.topic_id)

      // Set the focus state for the new entry (default to index 0 in topic panel)
      set_focus_state(
        container,
        history_graph.FocusState(
          mentions_index: 0,
          comments_index: 0,
          topic_index: 0,
          references_index: 0,
          active_panel: history_graph.TopicPanel,
        ),
      )

      // Load source text and replace
      // DOM elements. We wait to replace DOM elements until after
      // we have the source text so that there is no flicker when
      // navigating to a new topic due to unloaded DOM elements
      // but no new context to replace it with yet.
      audit_data.with_topic_data(
        audit_data.Topic(id: new_entry.topic_id),
        fn(metadata, _source_text, _comments) {
          let view =
            TopicView(entry_id: new_entry.id, topic_id: new_entry.topic_id)
          set_topic_view(new_entry.id, view)
          set_active_panel(container, history_graph.TopicPanel)
          repopulate_view(container, view, metadata)
        },
      )
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

        Ok(#(parent_entry, focus_state)) -> {
          case get_topic_view(parent_entry.id) {
            Ok(parent_view) -> {
              // Update the parent entry so that the child that this came from
              // is the first child, and has an updated focus state
              let other_children =
                parent_entry.children
                |> list.filter(fn(child) { child.id != active_view.entry_id })
              let updated_parent =
                history_graph.HistoryEntry(..parent_entry, children: [
                  history_graph.Relative(
                    active_view.entry_id,
                    get_current_focus_state(container),
                  ),
                  ..other_children
                ])
              history_graph.set_history_entry(updated_parent.id, updated_parent)

              // Update the URL to reflect the active topic
              update_url_for_topic(parent_entry.topic_id)

              // Set the focus state for restoration
              set_focus_state(container, focus_state)

              // Load source text and restore scroll position. We wait to reset
              // DOM elements until after we have the source text so that
              // there is no flicker when navigating to a new topic.
              let parent_topic = audit_data.Topic(id: parent_entry.topic_id)
              audit_data.with_topic_data(
                parent_topic,
                fn(metadata, _source_text, _comments) {
                  repopulate_view(container, parent_view, metadata)
                },
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

        Ok(#(child_entry, focus_state)) -> {
          case get_topic_view(child_entry.id) {
            Error(Nil) ->
              snag.new("Child view not found for entry: " <> child_entry.id)
              |> snag.line_print
              |> io.println_error

            Ok(child_view) -> {
              // Update the URL to reflect the active topic
              update_url_for_topic(child_entry.topic_id)

              // Set the focus state for restoration
              set_focus_state(container, focus_state)

              // Load source text and restore scroll position. We wait to reset
              // DOM elements until after we have the source text so that
              // there is no flicker when navigating to a new topic.
              let child_topic = audit_data.Topic(id: child_entry.topic_id)
              audit_data.with_topic_data(
                child_topic,
                fn(metadata, _source_text, _comments) {
                  repopulate_view(container, child_view, metadata)
                },
              )

              Nil
            }
          }
        }
      }
    }
  }
}

pub fn reload_topic_on_screen(target_topic_id: String) -> Nil {
  reload_topic_chain(target_topic_id, [])
}

fn reload_topic_chain(topic_id: String, visited: List(String)) -> Nil {
  case list.contains(visited, topic_id) {
    True -> Nil
    False -> {
      case dromel.query_document(elements.topic_selector(topic_id)) {
        Ok(_) -> {
          let container = topic_view_container()
          case get_active_topic_view(container) {
            Ok(active_view) -> {
              audit_data.with_topic_data(
                audit_data.Topic(id: active_view.topic_id),
                fn(metadata, _source_text, _comments) {
                  repopulate_view(container, active_view, metadata)
                },
              )
            }
            Error(_) -> Nil
          }
        }
        Error(_) -> {
          // Topic not on screen — check if it's a comment and walk up
          audit_data.with_topic_metadata(
            audit_data.Topic(id: topic_id),
            fn(result) {
              case result {
                Ok(audit_data.CommentTopic(target_topic:, ..)) ->
                  reload_topic_chain(target_topic, [topic_id, ..visited])
                _ -> Nil
              }
            },
          )
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

pub fn handle_topic_view_keydown(event) {
  let container = topic_view_container()

  case
    context.get_current_context(),
    event.ctrl_key(event),
    event.shift_key(event),
    event.key(event)
  {
    context.Input, _, _, _ -> Nil
    _, False, False, "h" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> navigate_into_mention(container)
        history_graph.CommentsPanel -> navigate_into_comment(container)
        history_graph.TopicPanel -> navigate_into_topic(container)
        history_graph.ReferencesPanel -> navigate_into_reference(container)
      }
    }

    _, False, False, "p" -> {
      event.prevent_default(event)
      navigate_back(container)
    }

    _, True, False, "p" -> {
      event.prevent_default(event)
      navigate_forward(container)
    }

    _, False, False, "ArrowRight" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> {
          gather_comments_tokens()
          set_active_panel(container, history_graph.CommentsPanel)
          move_to_comment_child(container, 0)
        }
        history_graph.CommentsPanel -> {
          set_active_panel(container, history_graph.TopicPanel)
          move_to_topic_child(container, 0)
        }
        history_graph.TopicPanel -> {
          gather_expanded_references_tokens()
          set_active_panel(container, history_graph.ReferencesPanel)
          move_to_reference_child(container, 0)
        }
        history_graph.ReferencesPanel -> Nil
      }
    }

    _, False, False, "ArrowLeft" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.ReferencesPanel -> {
          set_active_panel(container, history_graph.TopicPanel)
          move_to_topic_child(container, 0)
        }
        history_graph.TopicPanel -> {
          gather_comments_tokens()
          set_active_panel(container, history_graph.CommentsPanel)
          move_to_comment_child(container, 0)
        }
        history_graph.CommentsPanel -> {
          gather_mentions_tokens()
          set_active_panel(container, history_graph.MentionsPanel)
          move_to_mention_child(container, 0)
        }
        history_graph.MentionsPanel -> Nil
      }
    }

    _, False, False, "ArrowDown" | _, False, False, "," -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> move_to_mention_child(container, 1)
        history_graph.CommentsPanel -> move_to_comment_child(container, 1)
        history_graph.TopicPanel -> move_to_topic_child(container, 1)
        history_graph.ReferencesPanel -> move_to_reference_child(container, 1)
      }
    }
    _, False, True, "ArrowDown" | _, False, True, "<" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> move_to_mention_child(container, 10)
        history_graph.CommentsPanel -> move_to_comment_child(container, 10)
        history_graph.TopicPanel -> move_to_topic_child(container, 10)
        history_graph.ReferencesPanel -> move_to_reference_child(container, 10)
      }
    }

    _, False, False, "ArrowUp" | _, False, False, "e" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> move_to_mention_child(container, -1)
        history_graph.CommentsPanel -> move_to_comment_child(container, -1)
        history_graph.TopicPanel -> move_to_topic_child(container, -1)
        history_graph.ReferencesPanel -> move_to_reference_child(container, -1)
      }
    }
    _, False, True, "ArrowUp" | _, False, True, "E" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> move_to_mention_child(container, -10)
        history_graph.CommentsPanel -> move_to_comment_child(container, -10)
        history_graph.TopicPanel -> move_to_topic_child(container, -10)
        history_graph.ReferencesPanel -> move_to_reference_child(container, -10)
      }
    }

    _, False, False, "u" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        history_graph.MentionsPanel -> navigate_scope_up_mention(container)
        history_graph.CommentsPanel -> navigate_scope_up_comment(container)
        history_graph.TopicPanel -> navigate_scope_up_topic(container)
        history_graph.ReferencesPanel -> navigate_scope_up_reference(container)
      }
    }

    _, False, False, "c" -> {
      event.prevent_default(event)
      case get_active_view_elements() {
        Ok(elems) -> {
          let _ = dromel.focus(elems.comments_input)
          Nil
        }
        Error(Nil) -> Nil
      }
    }

    _, _, _, _ -> Nil
  }
}

fn navigate_into_topic(container) {
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

fn navigate_into_reference(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active topic view")
    Ok(elements) -> {
      case
        array.get(
          elements.expanded_references_tokens,
          get_current_references_index(container),
        )
        |> result.try(dromel.get_data(_, topic_key))
        |> result.map(audit_data.Topic)
      {
        Error(Nil) -> io.println_error("Unable to read reference topic")
        Ok(topic) -> {
          navigate_to_new_entry(container, topic)
        }
      }
    }
  }
}

fn navigate_into_mention(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active topic view")
    Ok(elements) -> {
      case
        array.get(
          elements.mentions_tokens,
          get_current_mentions_index(container),
        )
        |> result.try(dromel.get_data(_, topic_key))
        |> result.map(audit_data.Topic)
      {
        Error(Nil) -> io.println_error("Unable to read mention topic")
        Ok(topic) -> {
          navigate_to_new_entry(container, topic)
        }
      }
    }
  }
}

/// Navigate up one scope level in the topic panel
/// For member-grouped topics, collapses all topics in the group into a single member view
fn navigate_scope_up_topic(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active view elements")
    Ok(elements) -> {
      // Get the currently focused topic element
      case
        array.get(
          elements.topic_children_tokens,
          get_current_child_topic_index(container),
        )
      {
        Error(Nil) -> io.println_error("No topic element selected")
        Ok(focused_element) -> {
          // Get the element's id to restore focus after reload
          let focused_element_id =
            dromel.get_attribute(focused_element, "id") |> result.unwrap("")

          // Find the source container by traversing up from the focused element
          case find_source_container(focused_element) {
            Error(Nil) -> io.println_error("Unable to find source container")
            Ok(source_container) -> {
              // Check if this source container belongs to a member group
              case dromel.get_data(source_container, member_key) {
                Ok(member_id) -> {
                  // This is a member-grouped topic - collapse the group
                  collapse_member_group(
                    source_container,
                    member_id,
                    focused_element_id,
                    container,
                    history_graph.TopicPanel,
                  )
                }
                Error(Nil) -> {
                  // No member group - check for contract group
                  case dromel.get_data(source_container, contract_key) {
                    Ok(contract_id) -> {
                      // This is a contract-grouped topic - collapse to contract
                      collapse_contract_group(
                        source_container,
                        contract_id,
                        focused_element_id,
                        container,
                        history_graph.TopicPanel,
                      )
                    }
                    Error(Nil) -> {
                      // No contract group - already at top scope level
                      io.println("Already at top scope level")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Navigate up one scope level in the references panel (only affects the current reference preview)
/// For member-grouped references, collapses all references in the group into a single member view
fn navigate_scope_up_reference(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active view elements")
    Ok(elements) -> {
      // Get the currently focused reference element
      case
        array.get(
          elements.expanded_references_tokens,
          get_current_references_index(container),
        )
      {
        Error(Nil) -> io.println_error("No reference element selected")
        Ok(focused_element) -> {
          // Get the element's id to restore focus after reload
          let focused_element_id =
            dromel.get_attribute(focused_element, "id") |> result.unwrap("")

          // Find the source container by traversing up from the focused element
          case find_source_container(focused_element) {
            Error(Nil) -> io.println_error("Unable to find source container")
            Ok(source_container) -> {
              // Check if this source container belongs to a member group
              case dromel.get_data(source_container, member_key) {
                Ok(member_id) -> {
                  // This is a member-grouped reference - collapse the group
                  collapse_member_group(
                    source_container,
                    member_id,
                    focused_element_id,
                    container,
                    history_graph.ReferencesPanel,
                  )
                }
                Error(Nil) -> {
                  // No member group - check for contract group
                  case dromel.get_data(source_container, contract_key) {
                    Ok(contract_id) -> {
                      // This is a contract-grouped reference - collapse to contract
                      collapse_contract_group(
                        source_container,
                        contract_id,
                        focused_element_id,
                        container,
                        history_graph.ReferencesPanel,
                      )
                    }
                    Error(Nil) -> {
                      // No contract group - already at top scope level
                      io.println("Already at top scope level")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Navigate up one scope level in the mentions panel
/// For member-grouped mentions, collapses all mentions in the group into a single member view
fn navigate_scope_up_mention(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active view elements")
    Ok(elements) -> {
      // Get the currently focused mention element
      case
        array.get(
          elements.mentions_tokens,
          get_current_mentions_index(container),
        )
      {
        Error(Nil) -> io.println_error("No mention element selected")
        Ok(focused_element) -> {
          // Get the element's id to restore focus after reload
          let focused_element_id =
            dromel.get_attribute(focused_element, "id") |> result.unwrap("")

          // Find the source container by traversing up from the focused element
          case find_source_container(focused_element) {
            Error(Nil) -> io.println_error("Unable to find source container")
            Ok(source_container) -> {
              // Check if this source container belongs to a member group
              case dromel.get_data(source_container, member_key) {
                Ok(member_id) -> {
                  // This is a member-grouped mention - collapse the group
                  collapse_member_group(
                    source_container,
                    member_id,
                    focused_element_id,
                    container,
                    history_graph.MentionsPanel,
                  )
                }
                Error(Nil) -> {
                  // No member group - check for contract group
                  case dromel.get_data(source_container, contract_key) {
                    Ok(contract_id) -> {
                      // This is a contract-grouped mention - collapse to contract
                      collapse_contract_group(
                        source_container,
                        contract_id,
                        focused_element_id,
                        container,
                        history_graph.MentionsPanel,
                      )
                    }
                    Error(Nil) -> {
                      // No contract group - already at top scope level
                      io.println("Already at top scope level")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Remove all containers in an array except the first one (and their placeholder parents)
fn remove_containers_after_first(
  containers: array.Array(element.Element),
) -> Nil {
  containers
  |> array.to_list
  |> list.index_map(fn(elem, index) {
    case index > 0 {
      True -> {
        // Remove the placeholder parent div, not just the source container
        case dromel.parent_element(elem) {
          Ok(placeholder) -> {
            let _ = dromel.remove(placeholder)
            Nil
          }
          Error(Nil) -> {
            let _ = dromel.remove(elem)
            Nil
          }
        }
      }
      False -> Nil
    }
  })
  Nil
}

/// Restore focus to an element after re-gathering tokens for the specified panel
fn restore_panel_focus(
  container: element.Element,
  focused_element_id: String,
  panel: ActivePanel,
) -> Nil {
  case panel {
    history_graph.MentionsPanel -> gather_mentions_tokens()
    history_graph.CommentsPanel -> gather_comments_tokens()
    history_graph.TopicPanel -> gather_topic_panel_tokens()
    history_graph.ReferencesPanel -> gather_expanded_references_tokens()
  }

  case get_active_view_elements() {
    Error(Nil) -> Nil
    Ok(elements) -> {
      let tokens = case panel {
        history_graph.MentionsPanel -> elements.mentions_tokens
        history_graph.CommentsPanel -> elements.comments_tokens
        history_graph.TopicPanel -> elements.topic_children_tokens
        history_graph.ReferencesPanel -> elements.expanded_references_tokens
      }
      find_and_focus_element_by_id(
        container,
        panel,
        tokens,
        focused_element_id,
        0,
      )
    }
  }
}

/// Gather topic tokens for the topic panel
fn gather_topic_panel_tokens() -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens =
        dromel.query_element_all(
          active_elements.topic_panel,
          elements.topic_tokens_class,
        )
      set_active_view_elements(
        ActiveViewElements(..active_elements, topic_children_tokens: tokens),
      )
      Nil
    }
    Error(Nil) -> Nil
  }
}

/// Collapse all source containers in a member group into a single member view
fn collapse_member_group(
  source_container: element.Element,
  member_id: String,
  focused_element_id: String,
  container: element.Element,
  panel: ActivePanel,
) -> Nil {
  // Find the reference-group parent that contains all the source containers
  case find_reference_group(source_container) {
    Error(Nil) -> io.println_error("Unable to find reference group")
    Ok(group_container) -> {
      // Query all source containers with this member_id
      let member_containers =
        dromel.query_element_all(
          group_container,
          dromel.Selector("[data-member=\"" <> member_id <> "\"]"),
        )

      // Find the first container (the one with the member title)
      case array.get(member_containers, 0) {
        Error(Nil) -> io.println_error("No member containers found")
        Ok(first_container) -> {
          remove_containers_after_first(member_containers)

          // Update the first container to show the member's source
          let member_topic = audit_data.Topic(id: member_id)

          // Remove the member_key so further scope-up uses existing behavior
          let _ = dromel.remove_data(first_container, member_key)

          // Update the topic_key to the member
          let _ = dromel.set_data(first_container, topic_key, member_id)

          // Reapply first/last styles to all remaining containers in the group
          reapply_first_last_styles(group_container)

          // Load the member's source text
          audit_data.with_source_text(member_topic, fn(source_text) {
            case source_text {
              Ok(source_text) -> {
                // Keep the member title (first child), replace the rest
                case dromel.first_child(first_container) {
                  Ok(member_title) -> {
                    // Clear and rebuild content
                    dromel.set_inner_html(first_container, "")
                    dromel.append_child(first_container, member_title)

                    dromel.new_div()
                    |> dromel.set_inner_html(source_text)
                    |> dromel.append_as_child(to: first_container)
                    Nil
                  }
                  Error(Nil) -> {
                    // No member title, just set the content
                    dromel.set_inner_html(first_container, source_text)
                    Nil
                  }
                }

                restore_panel_focus(container, focused_element_id, panel)

                Nil
              }
              Error(error) -> {
                let _ =
                  dromel.set_inner_html(
                    first_container,
                    log.render_source_error(error),
                  )
                Nil
              }
            }
          })
        }
      }
    }
  }
}

/// Find the reference-group ancestor of an element
fn find_reference_group(elem: element.Element) -> Result(element.Element, Nil) {
  case dromel.has_class(elem, reference_group_class) {
    True -> Ok(elem)
    False ->
      case dromel.parent_element(elem) {
        Ok(parent) -> find_reference_group(parent)
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Collapse all source containers in a contract group into a single contract view
fn collapse_contract_group(
  source_container: element.Element,
  contract_id: String,
  focused_element_id: String,
  container: element.Element,
  panel: ActivePanel,
) -> Nil {
  // Find the reference-group parent that contains all the source containers
  case find_reference_group(source_container) {
    Error(Nil) -> io.println_error("Unable to find reference group")
    Ok(group_container) -> {
      // Query all source containers in this group
      let all_containers =
        dromel.query_element_all(
          group_container,
          elements.source_container_class,
        )

      // Find the first container
      case array.get(all_containers, 0) {
        Error(Nil) -> io.println_error("No source containers found")
        Ok(first_container) -> {
          remove_containers_after_first(all_containers)

          // Update the first container to show the contract's source
          let contract_topic = audit_data.Topic(id: contract_id)

          // Remove both member_key and contract_key so further scope-up uses existing behavior
          let _ = dromel.remove_data(first_container, member_key)
          let _ = dromel.remove_data(first_container, contract_key)

          // Update the topic_key to the contract
          let _ = dromel.set_data(first_container, topic_key, contract_id)

          // Apply first/last styles since this is now the only container
          apply_first_last_style(first_container, 0, 1)

          // Clear any member title that might exist
          let _ = dromel.set_inner_html(first_container, "")

          // Load the contract's source text
          audit_data.with_source_text(contract_topic, fn(source_text) {
            case source_text {
              Ok(text) -> {
                let _ =
                  dromel.new_div()
                  |> dromel.set_inner_html(text)
                  |> dromel.append_as_child(to: first_container)

                restore_panel_focus(container, focused_element_id, panel)

                Nil
              }
              Error(error) -> {
                let _ =
                  dromel.set_inner_html(
                    first_container,
                    log.render_source_error(error),
                  )
                Nil
              }
            }
          })
        }
      }
    }
  }
}

/// Find an element by id in the tokens array and focus it
fn find_and_focus_element_by_id(
  container,
  panel: ActivePanel,
  tokens: array.Array(element.Element),
  target_id: String,
  index: Int,
) -> Nil {
  case array.get(tokens, index) {
    Error(Nil) -> Nil
    Ok(el) -> {
      case dromel.get_attribute(el, "id") {
        Ok(id) if id == target_id -> {
          focus_topic_token_and_prefetch(el)
          case panel {
            history_graph.MentionsPanel ->
              set_current_mentions_index(container, index)
            history_graph.CommentsPanel ->
              set_current_comments_index(container, index)
            history_graph.TopicPanel ->
              set_current_child_topic_index(container, index)
            history_graph.ReferencesPanel ->
              set_current_references_index(container, index)
          }
          Nil
        }
        _ ->
          find_and_focus_element_by_id(
            container,
            panel,
            tokens,
            target_id,
            index + 1,
          )
      }
    }
  }
}

fn find_source_container(elem: element.Element) -> Result(element.Element, Nil) {
  case dromel.has_class(elem, elements.source_container_class) {
    True -> Ok(elem)
    False ->
      case dromel.parent_element(elem) {
        Ok(parent) -> find_source_container(parent)
        Error(Nil) -> Error(Nil)
      }
  }
}

fn move_to_topic_child(container, index_diff) {
  case get_active_view_elements() {
    Ok(elements) -> {
      let new_index = case
        get_current_child_topic_index(container) + index_diff
      {
        n if n <= 0 -> 0
        n ->
          case array.size(elements.topic_children_tokens) - 1 {
            size if n > size -> size
            _size -> n
          }
      }

      case elements.topic_children_tokens |> array.get(new_index) {
        Ok(el) -> {
          focus_topic_token_and_prefetch(el)
          set_current_child_topic_index(container, new_index)
        }
        Error(Nil) -> {
          io.println("no child index diff of " <> int.to_string(index_diff))
        }
      }
    }
    Error(Nil) -> {
      io.println_error("no active view")
    }
  }
}

fn move_to_reference_child(container, index_diff) {
  case get_active_view_elements() {
    Ok(elements) -> {
      let current_index = get_current_references_index(container)
      let new_index = case current_index + index_diff {
        n if n <= 0 -> 0
        n ->
          case array.size(elements.expanded_references_tokens) - 1 {
            size if n > size -> size
            _size -> n
          }
      }

      case elements.expanded_references_tokens |> array.get(new_index) {
        Ok(el) -> {
          focus_topic_token_and_prefetch(el)
          set_current_references_index(container, new_index)
        }
        Error(Nil) -> {
          io.println("no reference index diff of " <> int.to_string(index_diff))
        }
      }
    }
    Error(Nil) -> {
      io.println_error("no active view")
    }
  }
}

fn move_to_comment_child(container, index_diff) {
  case get_active_view_elements() {
    Ok(elements) -> {
      let current_index = get_current_comments_index(container)
      let new_index = case current_index + index_diff {
        n if n <= 0 -> 0
        n ->
          case array.size(elements.comments_tokens) - 1 {
            size if n > size -> size
            _size -> n
          }
      }

      case elements.comments_tokens |> array.get(new_index) {
        Ok(el) -> {
          focus_topic_token_and_prefetch(el)
          set_current_comments_index(container, new_index)
        }
        Error(Nil) -> {
          io.println("no comment index diff of " <> int.to_string(index_diff))
        }
      }
    }
    Error(Nil) -> {
      io.println_error("no active view")
    }
  }
}

fn move_to_mention_child(container, index_diff) {
  case get_active_view_elements() {
    Ok(elements) -> {
      let current_index = get_current_mentions_index(container)
      let new_index = case current_index + index_diff {
        n if n <= 0 -> 0
        n ->
          case array.size(elements.mentions_tokens) - 1 {
            size if n > size -> size
            _size -> n
          }
      }

      case elements.mentions_tokens |> array.get(new_index) {
        Ok(el) -> {
          focus_topic_token_and_prefetch(el)
          set_current_mentions_index(container, new_index)
        }
        Error(Nil) -> {
          io.println("no mention index diff of " <> int.to_string(index_diff))
        }
      }
    }
    Error(Nil) -> {
      io.println_error("no active view")
    }
  }
}

const reference_title_class = dromel.Class("topic-reference-title")

fn gather_mentions_tokens() -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens =
        dromel.query_element_all(
          active_elements.mentions_panel,
          elements.topic_tokens_class,
        )
      set_active_view_elements(
        ActiveViewElements(..active_elements, mentions_tokens: tokens),
      )
      Nil
    }
    Error(Nil) -> Nil
  }
}

fn gather_expanded_references_tokens() -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens =
        dromel.query_element_all(
          active_elements.expanded_references_panel,
          elements.topic_tokens_class,
        )
      set_active_view_elements(
        ActiveViewElements(
          ..active_elements,
          expanded_references_tokens: tokens,
        ),
      )
      Nil
    }
    Error(Nil) -> Nil
  }
}

fn gather_comments_tokens() -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens =
        dromel.query_element_all(
          active_elements.comments_panel,
          elements.topic_tokens_class,
        )
      set_active_view_elements(
        ActiveViewElements(..active_elements, comments_tokens: tokens),
      )
      Nil
    }
    Error(Nil) -> Nil
  }
}

fn navigate_into_comment(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active topic view")
    Ok(elements) -> {
      case
        array.get(
          elements.comments_tokens,
          get_current_comments_index(container),
        )
        |> result.try(dromel.get_data(_, topic_key))
        |> result.map(audit_data.Topic)
      {
        Error(Nil) -> io.println_error("Unable to read comment topic")
        Ok(topic) -> {
          navigate_to_new_entry(container, topic)
        }
      }
    }
  }
}

fn navigate_scope_up_comment(container) {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active view elements")
    Ok(elements) -> {
      case
        array.get(
          elements.comments_tokens,
          get_current_comments_index(container),
        )
      {
        Error(Nil) -> io.println_error("No comment element selected")
        Ok(focused_element) -> {
          let focused_element_id =
            dromel.get_attribute(focused_element, "id") |> result.unwrap("")

          case find_source_container(focused_element) {
            Error(Nil) -> io.println_error("Unable to find source container")
            Ok(source_container) -> {
              case dromel.get_data(source_container, member_key) {
                Ok(member_id) -> {
                  collapse_member_group(
                    source_container,
                    member_id,
                    focused_element_id,
                    container,
                    history_graph.CommentsPanel,
                  )
                }
                Error(Nil) -> {
                  case dromel.get_data(source_container, contract_key) {
                    Ok(contract_id) -> {
                      collapse_contract_group(
                        source_container,
                        contract_id,
                        focused_element_id,
                        container,
                        history_graph.CommentsPanel,
                      )
                    }
                    Error(Nil) -> {
                      io.println("Already at top scope level")
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn focus_topic_token_and_prefetch(element) {
  dromel.focus(element)

  case dromel.get_data(element, elements.token_topic_id_key) {
    Ok(topic_id) ->
      audit_data.with_topic_data(audit_data.Topic(topic_id), fn(_, _, _) { Nil })
    Error(Nil) -> io.println_error("No topic ID found for prefetch")
  }
}
