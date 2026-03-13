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
// Features Modal State
// ============================================================================

pub type FeaturesModalState {
  FeaturesModalState(
    all_features: List(audit_data.TopicMetadata),
    filtered_features: List(audit_data.TopicMetadata),
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

@external(javascript, "../mem_ffi.mjs", "get_features_modal_state")
fn get_features_modal_state() -> Result(FeaturesModalState, Nil)

@external(javascript, "../mem_ffi.mjs", "set_features_modal_state")
fn set_features_modal_state(state: FeaturesModalState) -> Nil

fn init_features_modal_state(
  left_pane: element.Element,
  right_pane: element.Element,
) -> Nil {
  set_features_modal_state(FeaturesModalState(
    all_features: [],
    filtered_features: [],
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

fn get_feature_name(feature: audit_data.TopicMetadata) -> String {
  case feature {
    audit_data.Feature(name:, ..) -> name
    _ -> audit_data.topic_metadata_name(feature)
  }
}

// ============================================================================
// Modal Mounting
// ============================================================================

fn mount_features_modal(container: element.Element) -> Nil {
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
    |> dromel.set_placeholder("Search features...")
    |> dromel.set_style(
      "width: 100%; padding: 0.5rem; background: var(--color-body-bg); color: var(--color-body-text); border: none; font-size: 14px; box-sizing: border-box;",
    )
    |> dromel.add_event_listener("input", fn(e) {
      case get_features_modal_state() {
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

  // Left pane (feature list)
  let left_pane =
    dromel.new_div()
    |> dromel.set_class(elements.modal_left_pane_class)
    |> dromel.add_class(elements.source_container_class)
    |> dromel.set_style(
      "background: var(--color-body-bg); padding: 0.5rem; flex: 1;",
    )
    |> dromel.set_inner_html(
      "<div style='color: var(--color-body-text); padding: 1rem;'>Loading features...</div>",
    )

  let _ = left_column |> dromel.append_child(search_container)
  let _ = left_column |> dromel.append_child(left_pane)

  // Right pane (preview)
  let right_pane =
    dromel.new_div()
    |> dromel.set_class(elements.modal_right_pane_class)
    |> dromel.add_class(elements.source_container_class)
    |> dromel.set_style(
      "background: var(--color-code-bg); padding: 1rem; overflow-y: auto;",
    )
    |> dromel.set_inner_html("Loading...")

  let _ = container |> dromel.append_child(left_column)
  let _ = container |> dromel.append_child(right_pane)

  // Initialize state with element references
  init_features_modal_state(left_pane, right_pane)
}

// ============================================================================
// Rendering Functions
// ============================================================================

fn render_feature_list(
  list_container: element.Element,
  features: List(audit_data.TopicMetadata),
  selected_index: Int,
  search_query: String,
) -> Nil {
  let _ = list_container |> dromel.set_inner_html("")

  case list.is_empty(features) {
    True -> {
      let empty_msg =
        dromel.new_div()
        |> dromel.set_inner_text("No features match filter")
        |> dromel.set_style("color: var(--color-body-text); padding: 1rem;")

      let _ = list_container |> dromel.append_child(empty_msg)
      Nil
    }
    False -> {
      features
      |> list.index_map(fn(feature, idx) {
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

        let name_container =
          dromel.new_div()
          |> dromel.set_style(
            "display: flex; align-items: center; gap: 0.5rem;",
          )

        let icon_container =
          dromel.new_span()
          |> dromel.set_style(
            "display: flex; align-items: center; flex-shrink: 0;",
          )
          |> dromel.set_inner_html(icons.sparkles)

        let feature_name = get_feature_name(feature)
        let highlighted_name =
          search.highlight_match(feature_name, search_query)

        let name_span =
          dromel.new_span()
          |> dromel.set_inner_html(highlighted_name)

        let _ = name_container |> dromel.append_child(icon_container)
        let _ = name_container |> dromel.append_child(name_span)
        let _ = item |> dromel.append_child(name_container)
        let _ = list_container |> dromel.append_child(item)

        case is_selected {
          True -> dromel.scroll_into_view(item)
          False -> Nil
        }

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

fn load_preview(feature: audit_data.TopicMetadata) -> Nil {
  case get_features_modal_state() {
    Ok(state) -> {
      let topic_id = feature.topic.id
      set_features_modal_state(
        FeaturesModalState(..state, current_preview_topic_id: Some(topic_id)),
      )

      dromel.set_inner_html(state.right_pane, "Loading preview...")

      // Fetch the feature's own source text first
      audit_data.with_source_text(feature.topic, fn(result) {
        case get_features_modal_state() {
          Ok(current_state) -> {
            case current_state.current_preview_topic_id {
              Some(current_id) if current_id == topic_id -> {
                // Clear and start building preview
                dromel.set_inner_html(current_state.right_pane, "")

                // Add feature source text
                let feature_section =
                  dromel.new_div()
                  |> dromel.set_inner_html(case result {
                    Ok(text) -> text
                    Error(error) -> log.render_source_error(error)
                  })

                let _ =
                  current_state.right_pane
                  |> dromel.append_child(feature_section)

                // Now load each requirement's source text
                let requirement_topics = case feature {
                  audit_data.Feature(requirement_topics:, ..) ->
                    requirement_topics
                  _ -> []
                }

                list.each(requirement_topics, fn(req_topic) {
                  // Create a placeholder for each requirement
                  let separator =
                    dromel.new_div()
                    |> dromel.set_style(
                      "border-top: 1px dashed var(--color-body-border); margin: 1rem 0;",
                    )

                  let req_section =
                    dromel.new_div()
                    |> dromel.set_inner_html("Loading...")

                  let _ =
                    current_state.right_pane
                    |> dromel.append_child(separator)
                  let _ =
                    current_state.right_pane
                    |> dromel.append_child(req_section)

                  audit_data.with_source_text(req_topic, fn(req_result) {
                    // Check we're still on the same preview
                    case get_features_modal_state() {
                      Ok(s) -> {
                        case s.current_preview_topic_id {
                          Some(cid) if cid == topic_id -> {
                            case req_result {
                              Ok(text) -> {
                                dromel.set_inner_html(req_section, text)
                                Nil
                              }
                              Error(error) -> {
                                dromel.set_inner_html(
                                  req_section,
                                  log.render_source_error(error),
                                )
                                Nil
                              }
                            }
                          }
                          _ -> Nil
                        }
                      }
                      Error(_) -> Nil
                    }
                  })
                })

                Nil
              }
              _ -> Nil
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

fn handle_search_input(query: String, state: FeaturesModalState) -> Nil {
  let filtered = search.filter(state.all_features, query, get_feature_name)

  set_features_modal_state(
    FeaturesModalState(
      ..state,
      filtered_features: filtered,
      selected_index: 0,
      search_query: query,
    ),
  )

  render_feature_list(state.left_pane, filtered, 0, query)

  case list.first(filtered) {
    Ok(feature) -> load_preview(feature)
    Error(_) -> Nil
  }
}

fn handle_keydown(
  e: event.Event(event.UIEvent(event.KeyboardEvent)),
  overlay: element.Element,
) -> Nil {
  let state = case get_features_modal_state() {
    Ok(state) -> state
    Error(_) -> panic as "no modal state"
  }
  let list_length = list.length(state.filtered_features)

  case event.key(e) {
    "Escape" -> {
      event.prevent_default(e)
      modal.close_modal(overlay)
      context.remove_context(context.FeaturesModal)
    }

    "ArrowDown" if list_length > 0 -> {
      event.prevent_default(e)
      let new_index = case state.selected_index + 1 >= list_length {
        True -> 0
        False -> state.selected_index + 1
      }

      set_features_modal_state(
        FeaturesModalState(..state, selected_index: new_index),
      )

      render_feature_list(
        state.left_pane,
        state.filtered_features,
        new_index,
        state.search_query,
      )

      case get_at(state.filtered_features, new_index) {
        Ok(feature) -> load_preview(feature)
        Error(_) -> Nil
      }
    }

    "ArrowUp" if list_length > 0 -> {
      event.prevent_default(e)
      let new_index = case state.selected_index - 1 < 0 {
        True -> list_length - 1
        False -> state.selected_index - 1
      }

      set_features_modal_state(
        FeaturesModalState(..state, selected_index: new_index),
      )

      render_feature_list(
        state.left_pane,
        state.filtered_features,
        new_index,
        state.search_query,
      )

      case get_at(state.filtered_features, new_index) {
        Ok(feature) -> load_preview(feature)
        Error(_) -> Nil
      }
    }

    "Enter" if list_length > 0 -> {
      event.prevent_default(e)

      case get_at(state.filtered_features, state.selected_index) {
        Ok(feature) -> {
          let container = topic_view.topic_view_container()

          topic_view.navigate_to_new_entry(container, feature.topic)

          modal.close_modal(overlay)
          context.remove_context(context.FeaturesModal)
        }
        Error(Nil) -> {
          io.println_error("No feature selected in features modal")
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
  let modal_elements = modal.open_modal(mount_features_modal)

  let _ =
    modal_elements.overlay
    |> dromel.add_event_listener("keydown", fn(e) {
      handle_keydown(e, modal_elements.overlay)
    })

  case dromel.query_document(elements.modal_search_input_class) {
    Ok(input) -> {
      let _ = input |> dromel.focus()
      Nil
    }
    Error(_) -> Nil
  }

  audit_data.with_audit_features(fn(result) { on_features_loaded(result) })

  context.add_context(context.FeaturesModal)
}

fn on_features_loaded(
  result: Result(List(audit_data.TopicMetadata), snag.Snag),
) -> Nil {
  case get_features_modal_state() {
    Ok(state) -> {
      case result {
        Error(error) -> {
          dromel.set_inner_html(state.left_pane, log.render_source_error(error))
          dromel.set_inner_html(state.right_pane, "")
          Nil
        }

        Ok(features) -> {
          case list.is_empty(features) {
            True -> {
              dromel.set_inner_html(
                state.left_pane,
                log.render_source_error(snag.new("No features found")),
              )
              dromel.set_inner_html(state.right_pane, "")
              Nil
            }

            False -> {
              set_features_modal_state(FeaturesModalState(
                all_features: features,
                filtered_features: features,
                selected_index: 0,
                current_preview_topic_id: None,
                search_query: "",
                left_pane: state.left_pane,
                right_pane: state.right_pane,
              ))

              render_feature_list(state.left_pane, features, 0, "")

              case list.first(features) {
                Ok(feature) -> load_preview(feature)
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
