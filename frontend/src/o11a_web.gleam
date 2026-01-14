import audit_data
import dromel
import gleam/io
import gleam/javascript/array
import gleam/list
import gleam/result
import plinth/browser/event
import plinth/browser/window
import snag
import ui/contracts_modal
import ui/elements
import ui/modal
import ui/topic_view

pub fn main() {
  io.println("Hello from o11a_web at " <> audit_data.audit_name())

  let _ = populate_audit_name_tag(audit_data.audit_name())

  // Create view container for topic views
  let _ = setup_view_container()

  audit_data.with_audit_contracts(fn(contracts) {
    case contracts {
      Error(snag) -> {
        echo snag.line_print(snag) as "contracts: "
        Nil
      }
      Ok(contracts) -> {
        // Fetch source text for each contract's topic
        contracts
        |> list.each(fn(contract) {
          audit_data.with_source_text(contract.topic, fn(source_text) {
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
          })
        })

        Nil
      }
    }
  })

  window.add_event_listener("keydown", fn(event) {
    // Only handle global shortcuts when not in input context
    case modal.is_in_input_context() {
      True -> Nil
      False -> {
        case event.key(event) {
          "t" -> {
            event.prevent_default(event)
            event.stop_propagation(event)
            contracts_modal.open()
          }
          "ArrowDown" -> {
            event.prevent_default(event)
            case topic_view.get_active_topic_view() {
              Ok(view) -> {
                let new_index = topic_view.get_current_child_topic_index() + 1

                case
                  view.children_topic_tokens
                  |> array.get(new_index)
                {
                  Ok(el) -> {
                    dromel.focus(el)
                    io.println(
                      "Focusing element with topic "
                      <> dromel.get_data(el, elements.token_topic_id_key)
                      |> result.unwrap("None"),
                    )
                    topic_view.set_current_child_topic_index(new_index)
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

          "ArrowUp" -> {
            event.prevent_default(event)
            case topic_view.get_active_topic_view() {
              Ok(view) -> {
                let new_index = topic_view.get_current_child_topic_index() - 1

                case
                  view.children_topic_tokens
                  |> array.get(new_index)
                {
                  Ok(el) -> {
                    dromel.focus(el)
                    io.println(
                      "Focusing element with topic "
                      <> dromel.get_data(el, elements.token_topic_id_key)
                      |> result.unwrap("None"),
                    )
                    topic_view.set_current_child_topic_index(new_index)
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
          _ -> Nil
        }
      }
    }
  })

  Ok(Nil)
}

pub fn populate_audit_name_tag(audit_name) {
  use header <- result.try(dromel.query_document(elements.dynamic_header_sel))

  let audit_name_tag =
    dromel.new_span()
    |> dromel.set_inner_text(audit_name)
    |> dromel.set_style("margin-right: 0.5rem")

  let _ = header |> dromel.append_child(audit_name_tag)

  Ok(Nil)
}

fn setup_view_container() {
  let view_container =
    dromel.new_div()
    |> dromel.set_style("flex: 1; min-height: 0")

  let _ = audit_data.app_element() |> dromel.append_child(view_container)

  audit_data.set_topic_view_container(view_container)
}
