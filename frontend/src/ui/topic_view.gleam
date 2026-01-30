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
import core/log
import dromel
import gleam/int
import gleam/io
import gleam/javascript/array
import gleam/list
import gleam/option
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
/// on navigation, but scroll_position is preserved to restore the view state.
pub type TopicView {
  TopicView(entry_id: String, topic_id: String, scroll_position: Float)
}

/// ActivePanel tracks which panel currently has keyboard focus
pub type ActivePanel {
  TopicPanel
  ReferencesPanel
}

/// Identifies which token array field to update in ActiveViewElements
type TokenField {
  TopicPanelTokens
  ReferencesPanelTokens
}

/// Configuration for rendering a panel with grouped source containers
type GroupedSourcePanelConfig {
  GroupedSourcePanelConfig(
    /// The container element to render into
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
    previous_topic_scope: element.Element,
    previous_topic_panel: element.Element,
    previous_topic_container: element.Element,
    topic_panel: element.Element,
    topic_container: element.Element,
    expanded_references_panel: element.Element,
    expanded_references_container: element.Element,
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
      "display: flex; flex: 1; min-height: 0; justify-content: center; gap: 0.5rem; background: var(--color-body-bg);",
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
    let contract_ids = [group.contract.id]
    let contract_ref_ids = list.map(group.contract_references, fn(t) { t.id })
    let member_ids =
      list.flat_map(group.member_references, fn(member_group) {
        [
          member_group.member.id,
          ..list.map(member_group.references, fn(t) { t.id })
        ]
      })
    list.flatten([contract_ids, contract_ref_ids, member_ids])
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
    Ok(audit_data.NamedTopic(ancestors:, descendants:, expanded_references:, ..))
    | Ok(audit_data.NamedMutableTopic(
        ancestors:,
        descendants:,
        expanded_references:,
        ..,
      )) -> {
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

const current_child_topic_index_key = dromel.DataKey(
  "current_child_topic_index",
)

const current_references_index_key = dromel.DataKey("current_references_index")

const active_panel_key = dromel.DataKey("active_panel")

const topic_key = dromel.DataKey("topic")

const member_key = dromel.DataKey("member")

const contract_key = dromel.DataKey("contract")

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

fn set_active_panel(container: element.Element, panel: ActivePanel) -> Nil {
  let panel_str = case panel {
    TopicPanel -> "topic"
    ReferencesPanel -> "references"
  }
  let _ = dromel.set_data(container, active_panel_key, panel_str)
  Nil
}

fn get_active_panel(container: element.Element) -> ActivePanel {
  case dromel.get_data(container, active_panel_key) {
    Ok("references") -> ReferencesPanel
    _ -> TopicPanel
  }
}

// ============================================================================
// View Mounting and Removal
// ============================================================================

// 40ch for the source width, 1rem for the padding widths, 2px for the borders wid
const container_style = "position: relative; padding-top: 0.5rem; width: calc(40ch + 1rem + 2px);"

const panel_style = "min-height: 0; height: 100%; width: unset;"

const combined_panel_first_style = "border-top: 1px solid var(--color-body-border); border-top-right-radius: 8px; border-top-left-radius: 8px;"

const combined_panel_last_style = "border-bottom-right-radius: 8px; border-bottom-left-radius: 8px; border-bottom: 1px solid var(--color-body-border);"

const combined_panel_style = "border-right: 1px solid var(--color-body-border); border-left: 1px solid var(--color-body-border); border-bottom: 1px dashed var(--color-body-border); padding: 0.5rem; background: var(--color-code-bg); max-height: 100%;"

const combined_panel_member_title_style = "outline: 1px solid var(--color-body-border); border-radius: 4px; margin-bottom: 0.5rem; background: var(--color-body-bg); padding-left: 0.5rem;"

const scope_style = "position: relative; display: inline-flex; align-items: center; gap: 0.25rem; margin-bottom: 0.5rem; padding-right: 0.5rem; direction: rtl; overflow: hidden;"

const scope_standard_class = dromel.Class("scope-standard")

const scope_expanded_class = dromel.Class("scope-expanded")

const reference_group_class = dromel.Class("reference-group")

const scope_overflow_gradient_style_hidden = "display: none;"

const scope_overflow_gradient_style_visible = "position: absolute; left: 0; top: 0; bottom: 0; width: 1.5rem; background: linear-gradient(to right, var(--color-body-bg), transparent); pointer-events: none;"

const footer_style = "position: absolute; bottom: 0.25rem; right: 0.5rem;"

fn mount_topic_view(container: element.Element) -> ActiveViewElements {
  // Create the previous topic panel element (muted border)
  let previous_topic_panel =
    dromel.new_div()
    |> dromel.set_class(elements.source_container_class)

  let previous_topic_scope =
    dromel.new_div()
    |> dromel.set_style(scope_style)
    |> dromel.add_class(scope_standard_class)

  let previous_topic_footer =
    dromel.new_div()
    |> dromel.set_inner_text("Previous Topic")
    |> dromel.set_style(footer_style)

  let previous_topic_container =
    dromel.new_div()
    |> dromel.set_style(container_style)
    |> dromel.append_child(previous_topic_scope)
    |> dromel.append_child(previous_topic_panel)
    |> dromel.append_child(previous_topic_footer)

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

  let _ = container |> dromel.append_child(previous_topic_container)
  let _ = container |> dromel.append_child(topic_container)
  let _ = container |> dromel.append_child(expanded_references_container)

  let elements =
    ActiveViewElements(
      previous_topic_scope:,
      previous_topic_panel:,
      previous_topic_container:,
      topic_panel:,
      topic_container:,
      expanded_references_panel:,
      expanded_references_container:,
      topic_children_tokens: array.from_list([]),
      expanded_references_tokens: array.from_list([]),
    )

  set_active_view_elements(elements)

  elements
}

/// Save scroll position and remove DOM elements for the active view
/// Save scroll position and reset DOM elements for reuse (avoids flickering)
/// Returns the existing elements with their content cleared
fn reset_active_view(
  container: element.Element,
) -> Result(ActiveViewElements, Nil) {
  case get_active_topic_view(container), get_active_view_elements() {
    Ok(view), Ok(elements) -> {
      // Save scroll position before resetting
      let scroll_pos = dromel.get_scroll_top(elements.topic_panel)
      let updated_view = TopicView(..view, scroll_position: scroll_pos)
      set_topic_view(view.entry_id, updated_view)

      // Clear inner HTML of panels and reset scroll positions
      let _ = dromel.set_inner_html(elements.previous_topic_panel, "")
      let _ = dromel.set_inner_html(elements.previous_topic_scope, "")
      let _ = elements.previous_topic_panel |> dromel.set_style("")
      dromel.set_scroll_top(elements.previous_topic_panel, 0.0)

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
          topic_children_tokens: array.from_list([]),
          expanded_references_tokens: array.from_list([]),
        )
      set_active_view_elements(reset_elements)

      Ok(reset_elements)
    }
    _, _ -> Error(Nil)
  }
}

// ============================================================================
// Source Text Loading Callbacks
// ============================================================================

/// Specifies how to restore focus after loading source text
type FocusTarget {
  /// Focus the child at the given index with a specific scroll position
  FocusByIndex(index: Int, scroll_position: Float)
}

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
fn populate_reference_source(
  reference_source: element.Element,
  source_text: Result(String, snag.Snag),
) -> Nil {
  case source_text {
    Ok(source_text) -> {
      let _ =
        dromel.new_div()
        |> dromel.set_inner_html(source_text)
        |> dromel.append_as_child(to: reference_source)
      Nil
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

    mount_breadcrumb_parts(contract_scope, [TopicPart(ref_group.contract)])

    // Calculate total reference count for first/last styling
    let total_references =
      list.length(ref_group.contract_references)
      + list.fold(ref_group.member_references, 0, fn(acc, member_group) {
        acc + list.length(member_group.references)
      })

    // Render contract-level references
    let index_after_contract =
      list.index_fold(ref_group.contract_references, 0, fn(index, ref_topic, _) {
        let source_placeholder =
          dromel.new_div()
          |> dromel.append_as_child(to: group_container)

        audit_data.with_topic_data(ref_topic, fn(_metadata, source_text) {
          let reference_source =
            dromel.new_div()
            |> dromel.add_class(elements.source_container_class)
            |> dromel.set_data(topic_key, ref_topic.id)
            |> dromel.set_data(contract_key, ref_group.contract.id)
            |> dromel.set_style(combined_panel_style)
            |> dromel.add_style("padding-left: 0.5rem;")

          apply_first_last_style(reference_source, index, total_references)
          populate_reference_source(reference_source, source_text)

          let _ =
            source_placeholder
            |> dromel.append_child(reference_source)

          // Re-gather tokens after each source loads
          gather_panel_tokens(config)

          Nil
        })

        index + 1
      })

    // Render member-level references, grouped by member
    list.fold(
      ref_group.member_references,
      index_after_contract,
      fn(current_index, member_group) {
        // Track whether this is the first reference in the member group
        list.index_fold(
          member_group.references,
          current_index,
          fn(index, ref_topic, member_ref_index) {
            let source_placeholder =
              dromel.new_div()
              |> dromel.append_as_child(to: group_container)

            audit_data.with_topic_data(ref_topic, fn(_metadata, source_text) {
              let reference_source =
                dromel.new_div()
                |> dromel.add_class(elements.source_container_class)
                |> dromel.set_data(topic_key, ref_topic.id)
                |> dromel.set_data(member_key, member_group.member.id)
                |> dromel.set_data(contract_key, ref_group.contract.id)
                |> dromel.set_style(combined_panel_style)
                |> dromel.add_style("padding-left: 0.5rem;")

              apply_first_last_style(reference_source, index, total_references)

              // Add member title only for the first reference in the member group
              case member_ref_index {
                0 -> {
                  let member_title =
                    dromel.new_div()
                    |> dromel.set_style(combined_panel_member_title_style)
                    |> dromel.set_inner_html("...")
                    |> dromel.append_as_child(to: reference_source)

                  audit_data.with_topic_metadata(
                    member_group.member,
                    fn(metadata: Result(audit_data.TopicMetadata, snag.Snag)) -> Nil {
                      case metadata {
                        Ok(metadata) -> {
                          member_title
                          |> dromel.set_inner_html(
                            audit_data.topic_metadata_highlighted_name(metadata),
                          )
                          Nil
                        }
                        Error(snag) -> {
                          member_title
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

              populate_reference_source(reference_source, source_text)

              let _ =
                source_placeholder
                |> dromel.append_child(reference_source)

              // Re-gather tokens after each source loads
              gather_panel_tokens(config)

              Nil
            })

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
        dromel.query_element_all(config.panel, elements.source_topic_tokens)
      case config.token_field {
        TopicPanelTokens ->
          set_active_view_elements(
            ActiveViewElements(..active_elements, topic_children_tokens: tokens),
          )
        ReferencesPanelTokens ->
          set_active_view_elements(
            ActiveViewElements(
              ..active_elements,
              expanded_references_tokens: tokens,
            ),
          )
      }
      Nil
    }
    Error(Nil) -> Nil
  }
}

/// Callback for loading topic metadata and populating the topic panel
fn populate_topic_panel(
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
  elements: ActiveViewElements,
) -> Nil {
  case metadata {
    Ok(metadata) -> {
      let references = case metadata {
        audit_data.NamedTopic(references:, ..)
        | audit_data.NamedMutableTopic(references:, ..) -> references
        _ -> []
      }

      // Clear the topic panel and use grouped source panel rendering
      let _ = dromel.set_inner_html(elements.topic_panel, "")

      populate_grouped_source_panel(
        GroupedSourcePanelConfig(
          panel: elements.topic_panel,
          token_field: TopicPanelTokens,
        ),
        references,
      )
    }
    Error(_snag) -> {
      let _ =
        elements.topic_panel
        |> dromel.set_inner_html(
          "<div style='color: var(--color-body-text); font-size: 0.9rem;'>Unable to load topic</div>",
        )
      Nil
    }
  }
}

/// Callback for loading topic metadata and populating the expanded references panel
fn populate_expanded_references_panel(
  metadata: Result(audit_data.TopicMetadata, snag.Snag),
  elements: ActiveViewElements,
) -> Nil {
  case metadata {
    Ok(metadata) -> {
      let expanded_references = case metadata {
        audit_data.NamedTopic(expanded_references:, ..)
        | audit_data.NamedMutableTopic(expanded_references:, ..) ->
          expanded_references
        _ -> []
      }

      populate_grouped_source_panel(
        GroupedSourcePanelConfig(
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

/// Load the previous topic panel content based on the parent entry in history
fn load_previous_topic_panel(
  entry_id: String,
  elements: ActiveViewElements,
) -> Nil {
  case history_graph.get_history_entry(entry_id) {
    Error(Nil) -> clear_previous_topic_panel(elements)
    Ok(entry) ->
      case entry.parent {
        option.None -> clear_previous_topic_panel(elements)
        option.Some(history_graph.Relative(id: parent_id, child_topic_index:)) ->
          case history_graph.get_history_entry(parent_id) {
            Error(Nil) -> clear_previous_topic_panel(elements)
            Ok(parent_entry) -> {
              // Get the stored scroll position for the parent view
              let scroll_position = case get_topic_view(parent_entry.id) {
                Ok(parent_view) -> parent_view.scroll_position
                Error(Nil) -> 0.0
              }

              let topic = audit_data.Topic(id: parent_entry.topic_id)
              audit_data.with_topic_data(topic, fn(metadata, source_text) {
                case source_text {
                  Ok(source_text) -> {
                    let _ =
                      elements.previous_topic_panel
                      |> dromel.set_style(
                        "border-radius: 8px; border: 1px solid var(--color-body-border); padding: 0.5rem; background: var(--color-code-bg); max-height: 100%;",
                      )
                      |> dromel.set_inner_html(source_text)
                    dromel.set_scroll_top(
                      elements.previous_topic_panel,
                      scroll_position,
                    )

                    // Highlight the previous topic index
                    let _ =
                      dromel.query_element_all(
                        elements.previous_topic_panel,
                        elements.source_topic_tokens,
                      )
                      |> array.get(child_topic_index)
                      |> result.map(fn(element) {
                        element
                        |> dromel.add_style("text-decoration: underline;")
                      })

                    // Update the scope breadcrumb
                    populate_topic_scope(
                      metadata,
                      elements.previous_topic_scope,
                      elements.previous_topic_panel,
                    )

                    Nil
                  }
                  Error(_) -> {
                    // Silently fail - previous topic panel is optional
                    Nil
                  }
                }
              })
            }
          }
      }
  }
}

fn clear_previous_topic_panel(elements: ActiveViewElements) -> Nil {
  let _ =
    elements.previous_topic_panel
    |> dromel.set_inner_html("")
    |> dromel.set_style("")
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
  metadata,
  scope_container: element.Element,
  source_panel: element.Element,
) -> Nil {
  case metadata {
    Ok(metadata) -> {
      mount_scope_breadcrumb(scope_container, metadata)
      audit_data.with_is_in_scope(metadata.scope, fn(is_in_scope) {
        case is_in_scope {
          True -> Nil
          False -> {
            dromel.add_style(
              source_panel,
              "border-color: var(--color-body-out-of-scope-bg)",
            )
            Nil
          }
        }
      })
    }
    Error(_) -> {
      let _ = dromel.set_inner_html(scope_container, "Unable to Fetch")
      Nil
    }
  }
}

/// A part of a breadcrumb - either a file name string or a topic
type BreadcrumbPart {
  // For file names and other prefixes like "global"
  TextPart(String)
  TopicPart(audit_data.Topic)
}

/// Render breadcrumb parts into a container element
/// Creates breadcrumb elements separated by chevron_right icons
/// Parts should be in display order (will be reversed for RTL container)
fn mount_breadcrumb_parts(
  container: element.Element,
  parts: List(BreadcrumbPart),
) -> Nil {
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

/// Mount a breadcrumb display for a topic's scope
/// Shows component > member (excludes file name and topic name)
fn mount_scope_breadcrumb(
  container: element.Element,
  metadata: audit_data.TopicMetadata,
) -> Nil {
  let _ = dromel.set_inner_html(container, "")
  let parts = case metadata.scope {
    audit_data.Global -> [TextPart("global"), TopicPart(metadata.topic)]
    audit_data.Container(..) -> [TopicPart(metadata.topic)]
    audit_data.Component(component:, ..)
    | audit_data.Member(component:, ..)
    | audit_data.SemanticBlock(component:, ..) -> [
      TopicPart(component),
    ]
  }
  mount_breadcrumb_parts(container, parts)
}

/// Mount a fully qualified name display for the current topic
/// Shows file name > scope topics > subject name with chevrons between them
fn mount_fully_qualified_name(
  container: element.Element,
  topic_id: String,
) -> Nil {
  let _ = dromel.set_inner_html(container, "")

  audit_data.with_topic_metadata(audit_data.Topic(id: topic_id), fn(result) {
    case result {
      Ok(metadata) -> {
        let parts = case metadata.scope {
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
        mount_breadcrumb_parts(container, parts)
      }
      Error(_) -> {
        let _ = dromel.set_inner_html(container, "Unable to Fetch")
        Nil
      }
    }
  })
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
  navigate_to_new_entry_with_focus(container, topic, FocusByIndex(0, 0.0))
}

/// Navigate to a new entry with a specific focus target
fn navigate_to_new_entry_with_focus(
  container: element.Element,
  topic: audit_data.Topic,
  _focus_target: FocusTarget,
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

      // Update the URL to reflect the active topic
      update_url_for_topic(new_entry.topic_id)

      // Update the fully qualified name display
      mount_fully_qualified_name(get_history_container(), new_entry.topic_id)

      // Load source text and replace
      // DOM elements. We wait to replace DOM elements until after
      // we have the source text so that there is no flicker when
      // navigating to a new topic due to unloaded DOM elements
      // but no new context to replace it with yet.
      audit_data.with_topic_data(
        audit_data.Topic(id: new_entry.topic_id),
        fn(metadata, _source_text) {
          // Reset DOM elements for reuse (saves scroll position, clears content)
          let elements = case reset_active_view(container) {
            Ok(elements) -> elements
            Error(Nil) -> mount_topic_view(container)
          }

          // Initialize view state (scroll position starts at 0 for new views)
          let view =
            TopicView(
              entry_id: new_entry.id,
              topic_id: new_entry.topic_id,
              scroll_position: 0.0,
            )
          set_topic_view(new_entry.id, view)

          // Set as active view
          set_active_topic_view(container, view, metadata)
          set_active_panel(container, TopicPanel)

          // Load previous topic panel content
          load_previous_topic_panel(new_entry.id, elements)

          // Populate topic panel with grouped sources
          populate_topic_panel(metadata, elements)

          // Load topic metadata and populate expanded references panel
          populate_expanded_references_panel(metadata, elements)
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

        Ok(#(parent_entry, _child_topic_index)) -> {
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

              // Update the URL to reflect the active topic
              update_url_for_topic(parent_entry.topic_id)

              // Update the fully qualified name display
              mount_fully_qualified_name(
                get_history_container(),
                parent_entry.topic_id,
              )

              // Load source text and restore scroll position. We wait to reset
              // DOM elements until after we have the source text so that
              // there is no flicker when navigating to a new topic.
              let parent_topic = audit_data.Topic(id: parent_entry.topic_id)
              audit_data.with_topic_data(
                parent_topic,
                fn(metadata, _source_text) {
                  // Reset DOM elements for reuse (saves scroll position, clears content)
                  let elements = case reset_active_view(container) {
                    Ok(elements) -> elements
                    Error(Nil) -> mount_topic_view(container)
                  }

                  set_active_topic_view(container, parent_view, metadata)
                  set_active_panel(container, TopicPanel)

                  // Load previous topic panel content
                  load_previous_topic_panel(parent_entry.id, elements)

                  // Populate topic panel with grouped sources
                  populate_topic_panel(metadata, elements)

                  // Load topic metadata and populate expanded references panel
                  populate_expanded_references_panel(metadata, elements)
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

        Ok(#(child_entry, _child_topic_index)) -> {
          case get_topic_view(child_entry.id) {
            Error(Nil) ->
              snag.new("Child view not found for entry: " <> child_entry.id)
              |> snag.line_print
              |> io.println_error

            Ok(child_view) -> {
              // Update the URL to reflect the active topic
              update_url_for_topic(child_entry.topic_id)

              // Update the fully qualified name display
              mount_fully_qualified_name(
                get_history_container(),
                child_entry.topic_id,
              )

              // Load source text and restore scroll position. We wait to reset
              // DOM elements until after we have the source text so that
              // there is no flicker when navigating to a new topic.
              let child_topic = audit_data.Topic(id: child_entry.topic_id)
              audit_data.with_topic_data(
                child_topic,
                fn(metadata, _source_text) {
                  // Reset DOM elements for reuse (saves scroll position, clears content)
                  let elements = case reset_active_view(container) {
                    Ok(elements) -> elements
                    Error(Nil) -> mount_topic_view(container)
                  }

                  set_active_topic_view(container, child_view, metadata)
                  set_active_panel(container, TopicPanel)

                  // Populate topic panel with grouped sources
                  populate_topic_panel(metadata, elements)

                  // Load previous topic panel content
                  load_previous_topic_panel(child_entry.id, elements)

                  // Load topic metadata and populate expanded references panel
                  populate_expanded_references_panel(metadata, elements)
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

  case event.ctrl_key(event), event.shift_key(event), event.key(event) {
    False, False, "h" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> navigate_into_topic(container)
        ReferencesPanel -> navigate_into_reference(container)
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

    False, False, "ArrowRight" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> {
          // Gather reference tokens lazily when entering references panel
          gather_expanded_references_tokens()
          set_active_panel(container, ReferencesPanel)
          // Focus the first reference token if available
          navigate_to_reference(container, 0)
        }
        ReferencesPanel -> Nil
      }
    }

    False, False, "ArrowLeft" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        ReferencesPanel -> {
          set_active_panel(container, TopicPanel)
          // Refocus the current topic child
          navigate_to_child(container, 0)
        }
        TopicPanel -> Nil
      }
    }

    False, False, "ArrowDown" | False, False, "," -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> navigate_to_child(container, 1)
        ReferencesPanel -> navigate_to_reference(container, 1)
      }
    }
    False, True, "ArrowDown" | False, True, "<" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> navigate_to_child(container, 10)
        ReferencesPanel -> navigate_to_reference(container, 10)
      }
    }

    False, False, "ArrowUp" | False, False, "e" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> navigate_to_child(container, -1)
        ReferencesPanel -> navigate_to_reference(container, -1)
      }
    }
    False, True, "ArrowUp" | False, True, "E" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> navigate_to_child(container, -10)
        ReferencesPanel -> navigate_to_reference(container, -10)
      }
    }

    False, False, "u" -> {
      event.prevent_default(event)
      case get_active_panel(container) {
        TopicPanel -> navigate_scope_up_topic(container)
        ReferencesPanel -> navigate_scope_up_reference(container)
      }
    }

    _, _, _ -> Nil
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
                    TopicPanel,
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
                        TopicPanel,
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
                    ReferencesPanel,
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
                        ReferencesPanel,
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
    TopicPanel -> gather_topic_panel_tokens()
    ReferencesPanel -> gather_expanded_references_tokens()
  }

  case get_active_view_elements() {
    Error(Nil) -> Nil
    Ok(elements) -> {
      let tokens = case panel {
        TopicPanel -> elements.topic_children_tokens
        ReferencesPanel -> elements.expanded_references_tokens
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
          elements.source_topic_tokens,
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
              Ok(text) -> {
                // Keep the member title (first child), replace the rest
                case dromel.first_child(first_container) {
                  Ok(member_title) -> {
                    // Clear and rebuild content
                    let _ = dromel.set_inner_html(first_container, "")
                    let _ = dromel.append_child(first_container, member_title)
                    let _ =
                      dromel.new_div()
                      |> dromel.set_inner_html(text)
                      |> dromel.append_as_child(to: first_container)
                    Nil
                  }
                  Error(Nil) -> {
                    // No member title, just set the content
                    let _ = dromel.set_inner_html(first_container, text)
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
            TopicPanel -> set_current_child_topic_index(container, index)
            ReferencesPanel -> set_current_references_index(container, index)
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

fn navigate_to_child(container, index_diff) {
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

fn navigate_to_reference(container, index_diff) {
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

const reference_title_class = dromel.Class("topic-reference-title")

fn gather_expanded_references_tokens() -> Nil {
  case get_active_view_elements() {
    Ok(active_elements) -> {
      let tokens =
        dromel.query_element_all(
          active_elements.expanded_references_panel,
          elements.source_topic_tokens,
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

fn focus_topic_token_and_prefetch(element) {
  let _ = dromel.focus(element)

  case dromel.get_data(element, elements.token_topic_id_key) {
    Ok(topic_id) ->
      audit_data.with_topic_data(audit_data.Topic(topic_id), fn(_, _) { Nil })
    Error(Nil) -> io.println_error("No topic ID found for prefetch")
  }
}
