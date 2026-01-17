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

  let _ = mount_history_container()

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

  let _ = header |> dromel.append_child(audit_name_tag)

  Ok(Nil)
}

pub fn mount_history_container() {
  use header <- result.try(dromel.query_document(elements.dynamic_header_sel))

  let history_container =
    dromel.new_span()
    |> dromel.set_style(
      "display: inline-flex; align-items: center; gap: 0.15rem; border-left: 1px solid var(--color-body-border); padding-left: 0.5rem; direction: rtl; overflow: hidden; flex: 1;",
    )

  let _ = header |> dromel.append_child(history_container)

  topic_view.set_history_container(history_container)

  Ok(Nil)
}

pub fn prefetch_hot() {
  // Prefetch audit contracts
  audit_data.with_audit_contracts(fn(contracts) {
    case contracts {
      Error(snag) ->
        snag.layer(snag, "Unable to fetch audit contracts")
        |> snag.line_print
        |> io.println_error

      Ok(contracts) -> {
        // Prefetch source text for each contract's topic
        list.each(contracts, fn(contract) {
          audit_data.with_source_text(contract.topic, fn(source_text) {
            case source_text {
              Error(snag) ->
                snag.layer(
                  snag,
                  "Unable to fetch source text for topic " <> contract.topic.id,
                )
                |> snag.line_print
                |> io.println_error

              Ok(_text) -> Nil
            }
          })
        })

        Nil
      }
    }
  })
}
