import audit_data
import context
import dromel
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import plinth/browser/event
import plinth/browser/window
import snag
import ui/contracts_modal
import ui/documents_modal
import ui/features_modal
import ui/elements
import ui/topic_view

pub fn main() {
  io.println("Hello from o11a_web at " <> audit_data.audit_name())

  context.init_context()

  let _ = populate_audit_name_tag(audit_data.audit_name())

  let _ = mount_history_container()

  let _ = prefetch_hot_data()

  audit_data.connect_audit_event_ws(
    on_topic_updated: topic_view.reload_topic_on_screen,
  )

  let _ = open_url()

  window.add_event_listener("keydown", handle_window_keydown)

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

fn prefetch_source_text(topic_id: String) -> Nil {
  audit_data.with_source_text(
    audit_data.Topic(id: topic_id),
    fn(source_text) {
      case source_text {
        Error(snag) ->
          snag.layer(
            snag,
            "Unable to fetch source text for topic " <> topic_id,
          )
          |> snag.line_print
          |> io.println_error

        Ok(_text) -> Nil
      }
    },
  )
}

pub fn prefetch_hot_data() {
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

  // Prefetch features and their requirements' source text
  audit_data.with_audit_features(fn(features) {
    case features {
      Error(snag) ->
        snag.layer(snag, "Unable to fetch audit features")
        |> snag.line_print
        |> io.println_error

      Ok(features) -> {
        list.each(features, fn(feature) {
          // Prefetch the feature's own source text
          audit_data.with_source_text(feature.topic, fn(source_text) {
            case source_text {
              Error(snag) ->
                snag.layer(
                  snag,
                  "Unable to fetch source text for topic "
                    <> feature.topic.id,
                )
                |> snag.line_print
                |> io.println_error

              Ok(_text) -> Nil
            }
          })

          // Prefetch requirement IDs and their source text
          audit_data.with_feature_requirements(
            feature.topic.id,
            fn(req_result) {
              case req_result {
                Ok(req_ids) ->
                  list.each(req_ids, fn(req_id) {
                    prefetch_source_text(req_id)
                  })
                Error(_) -> Nil
              }
            },
          )

        })

        Nil
      }
    }
  })

  // Prefetch documentation
  audit_data.with_audit_documents(fn(documents) {
    case documents {
      Error(snag) ->
        snag.layer(snag, "Unable to fetch documentation")
        |> snag.line_print
        |> io.println_error

      Ok(documents) -> {
        // Prefetch source text for each document's topic
        list.each(documents, fn(document) {
          audit_data.with_source_text(document.topic, fn(source_text) {
            case source_text {
              Error(snag) ->
                snag.layer(
                  snag,
                  "Unable to fetch source text for topic " <> document.topic.id,
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

fn open_url() {
  case window.pathname() |> string.split("/") {
    // URL pattern: /:audit_id/:topic_id
    ["", _audit_id, topic_id] -> {
      let container = topic_view.topic_view_container()
      topic_view.navigate_to_new_entry(
        container,
        audit_data.Topic(id: topic_id),
      )
    }
    _ -> Nil
  }
}

fn handle_window_keydown(event) {
  // Only handle global shortcuts when in default context
  case
    context.get_current_context(),
    event.key(event),
    event.ctrl_key(event),
    event.shift_key(event)
  {
    context.Default, "t", _, _ -> {
      event.prevent_default(event)
      event.stop_propagation(event)
      contracts_modal.open()
    }
    context.Default, "d", _, _ -> {
      event.prevent_default(event)
      event.stop_propagation(event)
      documents_modal.open()
    }
    context.Default, "f", _, _ -> {
      event.prevent_default(event)
      event.stop_propagation(event)
      features_modal.open()
    }
    context.Default, _, _, _ -> topic_view.handle_topic_view_keydown(event)
    _, _, _, _ -> Nil
  }
}
