import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/javascript/promise
import gleam/string
import snag

pub fn with_audit_contracts(audit_name, callback) {
  case read_contracts() {
    Ok(contracts) -> {
      callback(Ok(contracts))
      Nil
    }
    Error(_) -> {
      let promise = case read_contracts_promise() {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_audit_contracts(audit_name)
          set_contracts_promise(promise)
          promise
        }
      }

      promise.await(promise, fn(contracts) {
        case contracts {
          Ok(contracts) -> {
            set_contracts(contracts)
          }
          Error(_) -> Nil
        }
        callback(contracts)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

pub type Topic {
  Topic(id: String)
}

fn topic_decoder() -> decode.Decoder(Topic) {
  use id <- decode.field("id", decode.string)
  decode.success(Topic(id:))
}

pub type Contract {
  Contract(topic: Topic, name: String, kind: String, file_path: String)
}

fn contract_decoder() -> decode.Decoder(Contract) {
  use topic <- decode.field("topic", topic_decoder())
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string)
  use file_path <- decode.field("file_path", decode.string)
  decode.success(Contract(topic:, name:, kind:, file_path:))
}

@external(javascript, "./mem_ffi.mjs", "set_contracts_promise")
fn set_contracts_promise(
  promise: promise.Promise(Result(List(Contract), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_contracts_promise")
fn read_contracts_promise() -> Result(
  promise.Promise(Result(List(Contract), snag.Snag)),
  Nil,
)

@external(javascript, "./mem_ffi.mjs", "get_contracts")
fn read_contracts() -> Result(List(Contract), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_contracts")
fn set_contracts(contracts: List(Contract)) -> Nil

fn fetch_audit_contracts(audit_name) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/" <> audit_name <> "/contracts",
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let contracts =
    decode.run(resp.body, {
      use contracts <- decode.field(
        "contracts",
        decode.list(contract_decoder()),
      )
      decode.success(contracts)
    })
    |> snag.map_error(string.inspect)

  promise.resolve(contracts)
}
