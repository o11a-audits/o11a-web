import audit_data
import dromel
import gleam/io
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
  let _ = topic_view.setup_view_container()

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
