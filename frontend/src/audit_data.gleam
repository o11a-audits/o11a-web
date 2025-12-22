import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/javascript/promise
import gleam/string
import snag

@external(javascript, "./mem_ffi.mjs", "set_audit_name")
pub fn set_audit_name(name: String) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_audit_name")
fn get_audit_name() -> Result(String, Nil)

pub fn audit_name() -> String {
  case get_audit_name() {
    Ok(name) -> name
    Error(Nil) -> panic as "Failed to retrieve audit name"
  }
}

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

pub type ContractMetadata {
  ContractMetadata(
    topic: Topic,
    name: String,
    kind: ContractKind,
    file_path: String,
  )
}

pub type ContractKind {
  Contract
  Interface
  Library
  Abstract
}

pub fn contract_kind_to_string(kind: ContractKind) -> String {
  case kind {
    Contract -> "Contract"
    Interface -> "Interface"
    Library -> "Library"
    Abstract -> "Abstract"
  }
}

fn contract_kind_decoder() -> decode.Decoder(ContractKind) {
  use variant <- decode.then(decode.string)
  case variant {
    "Contract" -> decode.success(Contract)
    "Interface" -> decode.success(Interface)
    "Library" -> decode.success(Library)
    "Abstract" -> decode.success(Abstract)
    _ -> decode.failure(Contract, "ContractKind")
  }
}

fn contract_decoder() -> decode.Decoder(ContractMetadata) {
  use topic <- decode.field("topic", topic_decoder())
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", contract_kind_decoder())
  use file_path <- decode.field("file_path", decode.string)
  decode.success(ContractMetadata(topic:, name:, kind:, file_path:))
}

@external(javascript, "./mem_ffi.mjs", "set_contracts_promise")
fn set_contracts_promise(
  promise: promise.Promise(Result(List(ContractMetadata), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_contracts_promise")
fn read_contracts_promise() -> Result(
  promise.Promise(Result(List(ContractMetadata), snag.Snag)),
  Nil,
)

@external(javascript, "./mem_ffi.mjs", "get_contracts")
fn read_contracts() -> Result(List(ContractMetadata), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_contracts")
fn set_contracts(contracts: List(ContractMetadata)) -> Nil

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

@external(javascript, "./mem_ffi.mjs", "set_source_text_promise")
fn set_source_text_promise(
  topic_id: String,
  promise: promise.Promise(Result(String, snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_source_text_promise")
fn read_source_text_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(String, snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_source_text")
fn read_source_text(topic_id: String) -> Result(String, snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_source_text")
fn set_source_text(topic_id: String, text: String) -> Nil

fn fetch_source_text(audit_name: String, topic: Topic) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name
      <> "/source_text/"
      <> topic.id,
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_text_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  promise.resolve(Ok(resp.body))
}

pub fn with_source_text(audit_name: String, topic: Topic, callback) {
  case read_source_text(topic.id) {
    Ok(source_text) -> {
      callback(Ok(source_text))
      Nil
    }
    Error(_) -> {
      let promise = case read_source_text_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_source_text(audit_name, topic)
          set_source_text_promise(topic.id, promise)
          promise
        }
      }

      promise.await(promise, fn(source_text) {
        case source_text {
          Ok(source_text) -> {
            set_source_text(topic.id, source_text)
          }
          Error(_) -> Nil
        }
        callback(source_text)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}
