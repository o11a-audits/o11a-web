import audit_data
import elements
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import plinth/browser/document
import plinth/browser/element
import plinth/browser/event
import plinth/browser/window
import snag

pub fn main() {
  let assert Ok(audit_name) = extract_audit_name()
  io.println("Hello from o11a_web at " <> audit_name)

  let _ = populate_audit_name_tag(audit_name)

  audit_data.with_audit_contracts(audit_name, fn(contracts) {
    case contracts {
      Error(snag) -> {
        echo snag.line_print(snag) as "contracts: "
        Nil
      }
      Ok(contracts) -> {
        echo contracts as "contracts: "

        // Fetch source text for each contract's topic
        contracts
        |> list.each(fn(contract) {
          audit_data.with_source_text(
            audit_name,
            contract.topic,
            fn(source_text) {
              case source_text {
                Error(snag) -> {
                  echo snag.line_print(snag) as "source_text error: "
                  Nil
                }
                Ok(text) -> {
                  echo text as "source_text for " <> contract.topic.id <> ": "
                  Nil
                }
              }
            },
          )
        })

        Nil
      }
    }
  })

  window.add_event_listener("keydown", fn(event) {
    case event.key(event) {
      "t" -> {
        event.prevent_default(event)
        event.stop_propagation(event)

        audit_data.with_audit_contracts(audit_name, fn(contracts) {
          case contracts {
            Error(snag) -> {
              echo snag.line_print(snag) as "contracts: "
              Nil
            }
            Ok(contracts) -> {
              echo contracts as "contracts: "

              // Fetch source text for each contract's topic
              contracts
              |> list.each(fn(contract) {
                audit_data.with_source_text(
                  audit_name,
                  contract.topic,
                  fn(source_text) {
                    case source_text {
                      Error(snag) -> {
                        echo snag.line_print(snag) as "source_text error: "
                        Nil
                      }
                      Ok(text) -> {
                        echo text as "source_text for "
                        <> contract.topic.id
                        <> ": "
                        Nil
                      }
                    }
                  },
                )
              })

              Nil
            }
          }
        })
      }
      _ -> Nil
    }
  })

  Ok(Nil)
}

pub fn populate_audit_name_tag(audit_name) {
  use header <- result.try(document.query_selector(
    elements.dynamic_header.selector,
  ))

  let audit_name_tag = document.create_element("span")
  element.set_inner_text(audit_name_tag, audit_name)
  element.set_attribute(audit_name_tag, "style", "margin-right: 0.5rem")

  element.append_child(header, audit_name_tag)

  Ok(Nil)
}

// Extract audit name from pathname
// For a path like "/my-audit", this returns "my-audit"
pub fn extract_audit_name() {
  case window.pathname() |> echo |> string.split("/") |> echo {
    ["", audit_name, ..] -> Ok(audit_name)
    _ -> Error(Nil)
  }
}
