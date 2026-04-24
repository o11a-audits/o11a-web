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
import core/user
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

/// How to determine initial focus when populating a view
type FocusStrategy {
  /// New entry: focus the declaring node matching this topic_id
  FocusOnDeclaringNode(topic_id: String)
  /// Restored navigation: find tokens by their data-node-topic identifiers
  RestoreFocusState(focus_state: history_graph.FocusState)
}

// ============================================================================
// Active View Elements (transient, only exists for currently displayed view)
// ============================================================================

const topic_panel_id = dromel.Id("topic-panel")

const expanded_references_panel_id = dromel.Id("expanded-references-panel")

type ActiveViewElements {
  ActiveViewElements(
    documentation_panel: element.Element,
    documentation_container: element.Element,
    conversation_panel: element.Element,
    conversation_container: element.Element,
    conversation_input: element.Element,
    topic_panel: element.Element,
    topic_container: element.Element,
    expanded_references_panel: element.Element,
    expanded_references_container: element.Element,
    documentation_tokens: array.Array(element.Element),
    conversation_tokens: array.Array(element.Element),
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

fn set_active_topic_view_entry(
  container: element.Element,
  view: TopicView,
) -> Nil {
  let _ = dromel.set_data(container, active_topic_view_key, view.entry_id)
  Nil
}

fn set_highlight_css(css: String) -> Nil {
  let style_id = dromel.Id(active_topic_style_id)
  case dromel.query_document(style_id) {
    Ok(style_element) -> {
      dromel.set_inner_text(style_element, css)
      Nil
    }
    Error(Nil) -> {
      let style_element =
        dromel.new("style")
        |> dromel.set_id(style_id)
        |> dromel.set_inner_text(css)
      let _ = audit_data.app_element() |> dromel.append_child(style_element)
      Nil
    }
  }
}

fn get_active_topic_view(container: element.Element) -> Result(TopicView, Nil) {
  dromel.get_data(container, active_topic_view_key)
  |> result.try(get_topic_view)
}

const active_panel_key = dromel.DataKey("active_panel")

const topic_key = dromel.DataKey("topic")

const member_key = dromel.DataKey("member")

const contract_key = dromel.DataKey("contract")

fn panel_index_key(panel: ActivePanel) -> dromel.DataKey {
  case panel {
    history_graph.DocumentationPanel ->
      dromel.DataKey("current_documentation_index")
    history_graph.ConversationPanel ->
      dromel.DataKey("current_conversation_index")
    history_graph.TopicPanel -> dromel.DataKey("current_child_topic_index")
    history_graph.ReferencesPanel -> dromel.DataKey("current_references_index")
  }
}

fn get_panel_index(container: element.Element, panel: ActivePanel) -> Int {
  dromel.get_data(container, panel_index_key(panel))
  |> result.try(int.parse)
  |> result.unwrap(0)
}

fn set_panel_index(
  container: element.Element,
  panel: ActivePanel,
  index: Int,
) -> Nil {
  let _ =
    dromel.set_data(container, panel_index_key(panel), int.to_string(index))
  Nil
}

fn get_panel_tokens(
  elements: ActiveViewElements,
  panel: ActivePanel,
) -> array.Array(element.Element) {
  case panel {
    history_graph.DocumentationPanel -> elements.documentation_tokens
    history_graph.ConversationPanel -> elements.conversation_tokens
    history_graph.TopicPanel -> elements.topic_children_tokens
    history_graph.ReferencesPanel -> elements.expanded_references_tokens
  }
}

fn set_panel_tokens(
  elements: ActiveViewElements,
  panel: ActivePanel,
  tokens: array.Array(element.Element),
) -> ActiveViewElements {
  case panel {
    history_graph.DocumentationPanel ->
      ActiveViewElements(..elements, documentation_tokens: tokens)
    history_graph.ConversationPanel ->
      ActiveViewElements(..elements, conversation_tokens: tokens)
    history_graph.TopicPanel ->
      ActiveViewElements(..elements, topic_children_tokens: tokens)
    history_graph.ReferencesPanel ->
      ActiveViewElements(..elements, expanded_references_tokens: tokens)
  }
}

fn get_panel_element(
  elements: ActiveViewElements,
  panel: ActivePanel,
) -> element.Element {
  case panel {
    history_graph.DocumentationPanel -> elements.documentation_panel
    history_graph.ConversationPanel -> elements.conversation_panel
    history_graph.TopicPanel -> elements.topic_panel
    history_graph.ReferencesPanel -> elements.expanded_references_panel
  }
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
  case dromel.get_data(container, active_panel_key) {
    Ok(data) -> {
      case history_graph.active_panel_from_string(data) {
        Ok(panel) -> panel
        Error(snag) -> {
          log.print_error(snag)
          history_graph.TopicPanel
        }
      }
    }
    Error(Nil) -> history_graph.TopicPanel
  }
}

fn get_current_focus_state(
  container: element.Element,
) -> history_graph.FocusState {
  history_graph.FocusState(
    documentation_node_topic: get_focused_node_topic(
      container,
      history_graph.DocumentationPanel,
    ),
    conversation_node_topic: get_focused_node_topic(
      container,
      history_graph.ConversationPanel,
    ),
    topic_node_topic: get_focused_node_topic(
      container,
      history_graph.TopicPanel,
    ),
    references_node_topic: get_focused_node_topic(
      container,
      history_graph.ReferencesPanel,
    ),
    active_panel: get_active_panel(container),
  )
}

/// Read the data-node-topic of the currently focused token in a panel
fn get_focused_node_topic(
  container: element.Element,
  panel: ActivePanel,
) -> String {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens = get_panel_tokens(active_elements, panel)
      let index = get_panel_index(container, panel)
      case array.get(tokens, index) {
        Ok(el) ->
          dromel.get_data(el, elements.node_topic_key)
          |> result.unwrap("")
        Error(Nil) -> ""
      }
    }
    Error(Nil) -> ""
  }
}

fn get_focus_state_node_topic(
  focus_state: history_graph.FocusState,
  panel: ActivePanel,
) -> String {
  case panel {
    history_graph.DocumentationPanel -> focus_state.documentation_node_topic
    history_graph.ConversationPanel -> focus_state.conversation_node_topic
    history_graph.TopicPanel -> focus_state.topic_node_topic
    history_graph.ReferencesPanel -> focus_state.references_node_topic
  }
}

// ============================================================================
// View Mounting and Removal
// ============================================================================

// 40ch for the source width, 1rem for the padding widths, 2px for the borders wid
const container_style = "position: relative; padding-top: 0.5rem; width: calc(40ch + 1rem + 2px);"

const panel_style = "min-height: 0; height: 100%; width: unset;"

const reference_group_class = dromel.Class("reference-group")

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
  // Create the documentation panel element
  let documentation_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let documentation_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Documentation")
    |> dromel.set_style(footer_style)

  let documentation_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(documentation_footer)
    |> dromel.append_child(documentation_panel)

  // Create the conversation panel element
  let conversation_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)
    |> dromel.set_style(panel_style)

  let comment_type_label =
    dromel.new_span()
    |> dromel.add_class(elements.code_style_class)

  let conversation_input =
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
                        user.id(),
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
                              move_focus_in_panel(
                                container,
                                get_active_panel(container),
                                0,
                              )
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
              focus_current_token(container, get_active_panel(container))
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

  let conversation_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Conversation")
    |> dromel.set_style(footer_style)

  let conversation_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(conversation_footer)
    |> dromel.append_child(comment_type_label)
    |> dromel.append_child(conversation_input)
    |> dromel.append_child(conversation_panel)

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

  let _ = container |> dromel.append_child(documentation_container)
  let _ = container |> dromel.append_child(conversation_container)
  let _ = container |> dromel.append_child(topic_container)
  let _ = container |> dromel.append_child(expanded_references_container)

  let elements =
    ActiveViewElements(
      documentation_panel:,
      documentation_container:,
      conversation_panel:,
      conversation_container:,
      conversation_input:,
      topic_panel:,
      topic_container:,
      expanded_references_panel:,
      expanded_references_container:,
      documentation_tokens: array.from_list([]),
      conversation_tokens: array.from_list([]),
      topic_children_tokens: array.from_list([]),
      expanded_references_tokens: array.from_list([]),
    )

  set_active_view_elements(elements)

  elements
}

/// Save scroll position and remove DOM elements for the active view
/// Save scroll position and reset DOM elements for reuse (avoids flickering)
/// Returns the existing elements with their content cleared
fn prepare_active_view() -> Result(ActiveViewElements, Nil) {
  case get_active_view_elements() {
    Ok(elements) -> {
      // Reset the topic panel style to default (removes out-of-scope border color)
      let _ = dromel.set_style(elements.topic_panel, panel_style)
      // Remove data attributes from previous view
      let _ = dromel.remove_data(elements.topic_panel, topic_key)
      let _ = dromel.remove_data(elements.topic_panel, member_key)
      let _ = dromel.remove_data(elements.topic_panel, contract_key)

      // Clear the documentation panel since it will be repopulated
      dromel.set_inner_html(elements.documentation_panel, "")

      // Reset the token arrays since content will be replaced by fetch callbacks
      let reset_elements =
        ActiveViewElements(
          ..elements,
          documentation_tokens: array.from_list([]),
          conversation_tokens: array.from_list([]),
          topic_children_tokens: array.from_list([]),
          expanded_references_tokens: array.from_list([]),
        )
      set_active_view_elements(reset_elements)

      Ok(reset_elements)
    }
    _ -> Error(Nil)
  }
}

/// Populate placeholder divs for inline info comments
fn inject_inline_info_comments(
  view_container: element.Element,
  panel_element: element.Element,
  panel: ActivePanel,
) -> Nil {
  let placeholders =
    dromel.query_element_all(panel_element, elements.placeholder_topic_sel)
    |> array.to_list

  list.each(placeholders, fn(placeholder) {
    case dromel.get_data(placeholder, elements.placeholder_topic_key) {
      Ok(topic_id) -> {
        audit_data.with_topic_info_comments(topic_id, fn(result) {
          case result {
            Ok(info_comment_ids) ->
              // Create placeholder divs synchronously to preserve comment order,
              // then populate each with source text when the async fetch resolves
              list.each(info_comment_ids, fn(comment_topic_id) {
                let comment_placeholder =
                  dromel.new_div()
                  |> dromel.set_class(elements.inline_comment_class)
                  |> dromel.add_class(elements.code_style_class)
                  |> dromel.append_as_child(to: placeholder)

                audit_data.with_source_text(
                  audit_data.Topic(id: comment_topic_id),
                  fn(source_text_result) {
                    case source_text_result {
                      Ok(source_text) -> {
                        dromel.set_inner_html(comment_placeholder, source_text)
                        // Re-gather tokens to include newly injected comment
                        gather_tokens_for_panel(view_container, panel)
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

// ============================================================================
// Scope Collapsing Helpers
// ============================================================================

const combined_panel_first_style = "border-top-width: 1px; border-top-style: solid; border-top-right-radius: 8px; border-top-left-radius: 8px;"

const combined_panel_last_style = "border-bottom-right-radius: 8px; border-bottom-left-radius: 8px; border-bottom-width: 1px; border-bottom-style: solid;"

fn apply_first_last_style(
  reference_source: element.Element,
  index: Int,
  total: Int,
) -> Nil {
  case index {
    0 -> {
      dromel.add_style(reference_source, combined_panel_first_style)
      Nil
    }
    _ -> Nil
  }
  case index == total - 1 {
    True -> {
      dromel.add_style(reference_source, combined_panel_last_style)
      Nil
    }
    False -> Nil
  }
}

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

// ============================================================================
// Public API
// ============================================================================

fn repopulate_view(
  container: element.Element,
  view: TopicView,
  focus_strategy: FocusStrategy,
) -> Nil {
  let elements = case prepare_active_view() {
    Ok(elements) -> elements
    Error(Nil) -> mount_topic_view(container)
  }

  set_active_topic_view_entry(container, view)

  let topic = audit_data.Topic(id: view.topic_id)

  // Fetch topic_view (topic panel, references, breadcrumb, highlight CSS)
  audit_data.fetch_topic_view(topic, fn(result) {
    case result {
      Ok(response) -> {
        dromel.set_inner_html(elements.topic_panel, response.topic_panel_html)
        dromel.set_inner_html(
          elements.expanded_references_panel,
          response.expanded_references_panel_html,
        )
        dromel.set_inner_html(get_history_container(), response.breadcrumb_html)
        set_highlight_css(response.highlight_css)

        inject_inline_info_comments(
          container,
          elements.topic_panel,
          history_graph.TopicPanel,
        )
        inject_inline_info_comments(
          container,
          elements.expanded_references_panel,
          history_graph.ReferencesPanel,
        )

        let active_panel = get_active_panel(container)
        gather_tokens_for_panel(container, history_graph.TopicPanel)
        gather_tokens_for_panel(container, history_graph.ReferencesPanel)

        case focus_strategy {
          FocusOnDeclaringNode(topic_id) ->
            focus_declaring_node(container, active_panel, topic_id)
          RestoreFocusState(focus_state) ->
            restore_focus_from_state(container, active_panel, focus_state)
        }
        Nil
      }
      Error(err) -> {
        elements.topic_panel
        |> dromel.set_inner_html(log.render_source_error(err))
        Nil
      }
    }
  })

  // Build documentation panel
  populate_documentation_panel(container, elements, view.topic_id)

  // Build conversation panel from existing endpoints
  populate_conversation_panel(container, elements, view.topic_id)
}

fn populate_documentation_panel(
  container: element.Element,
  elements: ActiveViewElements,
  topic_id: String,
) -> Nil {
  audit_data.with_documentation_html(
    [topic_id],
    fn(html_result) {
      case html_result {
        Ok(html) -> {
          dromel.set_inner_html(elements.documentation_panel, html)
          gather_tokens_for_panel(
            container,
            history_graph.DocumentationPanel,
          )
          Nil
        }
        Error(err) -> {
          snag.layer(
            err,
            "Failed to fetch documentation HTML for topic "
              <> topic_id,
          )
          |> log.print_error
          Nil
        }
      }
    },
  )
}

fn populate_conversation_panel(
  container: element.Element,
  elements: ActiveViewElements,
  topic_id: String,
) -> Nil {
  audit_data.with_conversation(topic_id, fn(result) {
    case result {
      Ok(entries) -> {
        dromel.set_inner_html(elements.conversation_panel, "")

        // Create placeholder divs synchronously to preserve entry order,
        // then populate each with thread HTML when the async fetch resolves
        list.each(entries, fn(entry) {
          let placeholder =
            dromel.new_div()
            |> dromel.set_style("margin-top: 0.5rem")
            |> dromel.append_as_child(to: elements.conversation_panel)

          audit_data.with_thread_html(entry.topic_id, fn(thread_result) {
            case thread_result {
              Ok(html) -> {
                dromel.set_inner_html(placeholder, html)
                gather_tokens_for_panel(
                  container,
                  history_graph.ConversationPanel,
                )
                Nil
              }
              Error(err) -> {
                snag.layer(err, "Failed to fetch thread for " <> entry.topic_id)
                |> log.print_error
                Nil
              }
            }
          })
        })
        Nil
      }
      Error(err) -> {
        snag.layer(err, "Failed to fetch conversation for topic " <> topic_id)
        |> log.print_error
        Nil
      }
    }
  })
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

      // Reset panel indices for the new entry
      set_panel_index(container, history_graph.DocumentationPanel, 0)
      set_panel_index(container, history_graph.ConversationPanel, 0)
      set_panel_index(container, history_graph.TopicPanel, 0)
      set_panel_index(container, history_graph.ReferencesPanel, 0)

      let view = TopicView(entry_id: new_entry.id, topic_id: new_entry.topic_id)
      set_topic_view(new_entry.id, view)
      set_active_panel(container, history_graph.TopicPanel)
      repopulate_view(container, view, FocusOnDeclaringNode(view.topic_id))
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

              set_active_panel(container, focus_state.active_panel)
              repopulate_view(
                container,
                parent_view,
                RestoreFocusState(focus_state),
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

              set_active_panel(container, focus_state.active_panel)
              repopulate_view(
                container,
                child_view,
                RestoreFocusState(focus_state),
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
              let focus_state = get_current_focus_state(container)
              set_active_panel(container, focus_state.active_panel)
              repopulate_view(
                container,
                active_view,
                RestoreFocusState(focus_state),
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
                  reload_topic_chain(target_topic.id, [topic_id, ..visited])
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
  let panel = get_active_panel(container)

  case
    context.get_current_context(),
    event.ctrl_key(event),
    event.shift_key(event),
    event.key(event)
  {
    context.Input, _, _, _ -> Nil
    _, False, False, "h" -> {
      event.prevent_default(event)
      navigate_into_panel(container, panel)
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
      case panel {
        history_graph.DocumentationPanel -> {
          gather_tokens_for_panel(container, history_graph.ConversationPanel)
          case panel_has_tokens(history_graph.ConversationPanel) {
            True -> {
              set_active_panel(container, history_graph.ConversationPanel)
              focus_current_token(container, history_graph.ConversationPanel)
            }
            False -> {
              set_active_panel(container, history_graph.TopicPanel)
              focus_current_token(container, history_graph.TopicPanel)
            }
          }
        }
        history_graph.ConversationPanel -> {
          let next = history_graph.TopicPanel
          set_active_panel(container, next)
          focus_current_token(container, next)
        }
        history_graph.TopicPanel -> {
          gather_tokens_for_panel(container, history_graph.ReferencesPanel)
          case panel_has_tokens(history_graph.ReferencesPanel) {
            True -> {
              set_active_panel(container, history_graph.ReferencesPanel)
              focus_current_token(container, history_graph.ReferencesPanel)
            }
            False -> Nil
          }
        }
        history_graph.ReferencesPanel -> Nil
      }
    }

    _, False, False, "ArrowLeft" -> {
      event.prevent_default(event)
      case panel {
        history_graph.ReferencesPanel -> {
          let next = history_graph.TopicPanel
          set_active_panel(container, next)
          focus_current_token(container, next)
        }
        history_graph.TopicPanel -> {
          gather_tokens_for_panel(container, history_graph.ConversationPanel)
          case panel_has_tokens(history_graph.ConversationPanel) {
            True -> {
              set_active_panel(container, history_graph.ConversationPanel)
              focus_current_token(container, history_graph.ConversationPanel)
            }
            False -> {
              gather_tokens_for_panel(
                container,
                history_graph.DocumentationPanel,
              )
              case panel_has_tokens(history_graph.DocumentationPanel) {
                True -> {
                  set_active_panel(container, history_graph.DocumentationPanel)
                  focus_current_token(
                    container,
                    history_graph.DocumentationPanel,
                  )
                }
                False -> Nil
              }
            }
          }
        }
        history_graph.ConversationPanel -> {
          gather_tokens_for_panel(container, history_graph.DocumentationPanel)
          case panel_has_tokens(history_graph.DocumentationPanel) {
            True -> {
              set_active_panel(container, history_graph.DocumentationPanel)
              focus_current_token(container, history_graph.DocumentationPanel)
            }
            False -> Nil
          }
        }
        history_graph.DocumentationPanel -> Nil
      }
    }

    _, False, False, "ArrowDown" | _, False, False, "," -> {
      event.prevent_default(event)
      move_focus_in_panel(container, panel, 1)
    }
    _, False, True, "ArrowDown" | _, False, True, "<" -> {
      event.prevent_default(event)
      move_focus_in_panel(container, panel, 10)
    }

    _, False, False, "ArrowUp" | _, False, False, "e" -> {
      event.prevent_default(event)
      move_focus_in_panel(container, panel, -1)
    }
    _, False, True, "ArrowUp" | _, False, True, "E" -> {
      event.prevent_default(event)
      move_focus_in_panel(container, panel, -10)
    }

    _, False, False, "u" -> {
      event.prevent_default(event)
      navigate_scope_up(container, panel)
    }

    _, False, False, "c" -> {
      event.prevent_default(event)
      case get_active_view_elements() {
        Ok(elems) -> {
          let _ = dromel.focus(elems.conversation_input)
          Nil
        }
        Error(Nil) -> Nil
      }
    }

    _, _, _, _ -> Nil
  }
}

fn navigate_into_panel(container: element.Element, panel: ActivePanel) -> Nil {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active topic view")
    Ok(elements) -> {
      case
        array.get(
          get_panel_tokens(elements, panel),
          get_panel_index(container, panel),
        )
        |> result.try(dromel.get_data(_, topic_key))
        |> result.map(audit_data.Topic)
      {
        Error(Nil) -> io.println_error("Unable to read topic")
        Ok(topic) -> navigate_to_new_entry(container, topic)
      }
    }
  }
}

/// Navigate up one scope level in the given panel.
/// For member-grouped items, collapses all items in the group into a single member view.
fn navigate_scope_up(container: element.Element, panel: ActivePanel) -> Nil {
  case get_active_view_elements() {
    Error(Nil) -> io.println_error("No active view elements")
    Ok(elements) -> {
      case
        array.get(
          get_panel_tokens(elements, panel),
          get_panel_index(container, panel),
        )
      {
        Error(Nil) -> io.println_error("No element selected")
        Ok(focused_element) -> {
          let focused_element_id =
            dromel.get_data(focused_element, elements.node_topic_key)
            |> result.unwrap("")

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
                    panel,
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
                        panel,
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
  gather_tokens_for_panel(container, panel)

  case get_active_view_elements() {
    Error(Nil) -> Nil
    Ok(elements) -> {
      find_and_focus_element_by_id(
        container,
        panel,
        get_panel_tokens(elements, panel),
        focused_element_id,
        0,
      )
    }
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
      case dromel.get_data(el, elements.node_topic_key) {
        Ok(id) if id == target_id -> {
          focus_topic_token_and_prefetch(el)
          set_panel_index(container, panel, index)
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

/// Focus the declaring node of a topic in the active panel.
/// Searches tokens for an element whose data-node-topic matches the topic_id,
/// falling back to index 0 if not found.
fn focus_declaring_node(
  container: element.Element,
  panel: ActivePanel,
  topic_id: String,
) -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens = get_panel_tokens(active_elements, panel)
      let index = find_token_index_by_node_topic(tokens, topic_id, 0)
      set_panel_index(container, panel, index)
      focus_current_token(container, panel)
    }
    Error(Nil) -> focus_current_token(container, panel)
  }
}

fn find_token_index_by_node_topic(
  tokens: array.Array(element.Element),
  topic_id: String,
  index: Int,
) -> Int {
  case array.get(tokens, index) {
    Error(Nil) -> 0
    Ok(el) ->
      case dromel.get_data(el, elements.node_topic_key) {
        Ok(node_topic) if node_topic == topic_id -> index
        _ -> find_token_index_by_node_topic(tokens, topic_id, index + 1)
      }
  }
}

/// Restore focus for the active panel using the node-topic identifiers
/// stored in the focus state.
fn restore_focus_from_state(
  container: element.Element,
  active_panel: ActivePanel,
  focus_state: history_graph.FocusState,
) -> Nil {
  let node_topic = get_focus_state_node_topic(focus_state, active_panel)
  case node_topic {
    "" -> focus_current_token(container, active_panel)
    _ -> {
      case get_active_view_elements() {
        Ok(active_elements) -> {
          let tokens = get_panel_tokens(active_elements, active_panel)
          let index = find_token_index_by_node_topic(tokens, node_topic, 0)
          set_panel_index(container, active_panel, index)
          focus_current_token(container, active_panel)
        }
        Error(Nil) -> focus_current_token(container, active_panel)
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

/// Focus the token at the current panel index without moving
fn focus_current_token(container: element.Element, panel: ActivePanel) -> Nil {
  move_focus_in_panel(container, panel, 0)
}

fn move_focus_in_panel(
  container: element.Element,
  panel: ActivePanel,
  index_diff: Int,
) -> Nil {
  case get_active_view_elements() {
    Ok(elements) -> {
      let tokens = get_panel_tokens(elements, panel)
      let current_index = get_panel_index(container, panel)
      let new_index = case current_index + index_diff {
        n if n <= 0 -> 0
        n ->
          case array.size(tokens) - 1 {
            size if n > size -> size
            _size -> n
          }
      }

      case array.get(tokens, new_index) {
        Ok(el) -> {
          focus_topic_token_and_prefetch(el)
          set_panel_index(container, panel, new_index)
        }
        Error(Nil) -> Nil
      }
    }
    Error(Nil) -> io.println_error("no active view")
  }
}

/// Gather tokens for a panel standalone (without a pre-built config)
fn gather_tokens_for_panel(
  _container: element.Element,
  panel: ActivePanel,
) -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let panel_el = get_panel_element(active_elements, panel)
      let tokens =
        dromel.query_element_all(panel_el, elements.topic_tokens_class)
      let updated = set_panel_tokens(active_elements, panel, tokens)
      set_active_view_elements(updated)
      Nil
    }
    Error(Nil) -> Nil
  }
}

/// Check if a panel has any focusable tokens after gathering them
fn panel_has_tokens(panel: ActivePanel) -> Bool {
  case get_active_view_elements() {
    Ok(elements) -> array.size(get_panel_tokens(elements, panel)) > 0
    Error(Nil) -> False
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
