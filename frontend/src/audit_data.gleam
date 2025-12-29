import dromel
import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/javascript/promise
import gleam/option.{None, Some}
import gleam/string
import plinth/browser/document
import plinth/browser/window
import snag

@external(javascript, "./mem_ffi.mjs", "set_audit_name")
fn set_audit_name(name: String) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_audit_name")
fn get_audit_name() -> Result(String, Nil)

pub fn audit_name() -> String {
  case get_audit_name() {
    Ok(name) -> name
    Error(Nil) -> {
      case window.pathname() |> echo |> string.split("/") {
        ["", audit_name, ..] -> {
          set_audit_name(audit_name)
          audit_name
        }
        _ -> panic as "Failed to retrieve audit name"
      }
    }
  }
}

@external(javascript, "./mem_ffi.mjs", "set_app_element")
fn set_app_element(element: dromel.Element) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_app_element")
fn get_app_element() -> Result(dromel.Element, Nil)

pub fn app_element() -> dromel.Element {
  case get_app_element() {
    Ok(element) -> element
    Error(Nil) ->
      case document.query_selector("#app") {
        Ok(element) -> {
          set_app_element(element)
          element
        }
        Error(Nil) -> panic as "Failed to retrieve app element"
      }
  }
}

pub fn with_audit_contracts(callback) {
  case read_contracts() {
    Ok(contracts) -> {
      callback(Ok(contracts))
      Nil
    }
    Error(_) -> {
      let promise = case read_contracts_promise() {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_audit_contracts()
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

pub type Scope {
  Container(container: String)
  Component(container: String, component: Topic)
  Member(container: String, component: Topic, member: Topic)
  Statement(
    container: String,
    component: Topic,
    member: Topic,
    statement: Topic,
  )
}

fn scope_decoder() -> decode.Decoder(Scope) {
  use scope_type <- decode.field("scope_type", decode.string)
  use container <- decode.field("container", decode.string)
  use maybe_component <- decode.optional_field(
    "component",
    None,
    decode.optional(decode.string),
  )
  use maybe_member <- decode.optional_field(
    "member",
    None,
    decode.optional(decode.string),
  )
  use maybe_statement <- decode.optional_field(
    "statement",
    None,
    decode.optional(decode.string),
  )

  case scope_type, maybe_component, maybe_member, maybe_statement {
    "Container", None, None, None -> {
      decode.success(Container(container: container))
    }
    "Component", Some(component), None, None -> {
      decode.success(Component(
        container: container,
        component: Topic(id: component),
      ))
    }
    "Member", Some(component), Some(member), None -> {
      decode.success(Member(
        container: container,
        component: Topic(id: component),
        member: Topic(id: member),
      ))
    }
    "Statement", Some(component), Some(member), Some(statement) -> {
      decode.success(Statement(
        container: container,
        component: Topic(id: component),
        member: Topic(id: member),
        statement: Topic(id: statement),
      ))
    }
    _, _, _, _ -> decode.failure(Container(container: ""), "Scope")
  }
}

pub type FunctionKind {
  Constructor
  Fallback
  Receive
  Function
  FreeFunction
}

pub type TopicKind {
  TopicContract(ContractKind)
  TopicFunction(FunctionKind)
  Modifier
  Event
  TopicError
  Struct
  Enum
  EnumMember
  Constant
  StateVariable
  LocalVariable
  OperatorInvocation
  DocumentationSection
  DocumentationParagraph
}

fn topic_kind_decoder() -> decode.Decoder(TopicKind) {
  use kind_str <- decode.field("kind", decode.string)
  use maybe_sub_kind <- decode.optional_field(
    "sub_kind",
    None,
    decode.optional(decode.string),
  )

  case kind_str, maybe_sub_kind {
    "Contract", Some("Contract") -> decode.success(TopicContract(Contract))
    "Contract", Some("Library") -> decode.success(TopicContract(Library))
    "Contract", Some("Abstract") -> decode.success(TopicContract(Abstract))
    "Contract", Some("Interface") -> decode.success(TopicContract(Interface))
    "Function", Some("Constructor") ->
      decode.success(TopicFunction(Constructor))
    "Function", Some("Fallback") -> decode.success(TopicFunction(Fallback))
    "Function", Some("Receive") -> decode.success(TopicFunction(Receive))
    "Function", Some("Function") -> decode.success(TopicFunction(Function))
    "Function", Some("FreeFunction") ->
      decode.success(TopicFunction(FreeFunction))
    "Modifier", None -> decode.success(Modifier)
    "Event", None -> decode.success(Event)
    "Error", None -> decode.success(TopicError)
    "Struct", None -> decode.success(Struct)
    "Enum", None -> decode.success(Enum)
    "EnumMember", None -> decode.success(EnumMember)
    "Constant", None -> decode.success(Constant)
    "StateVariable", None -> decode.success(StateVariable)
    "LocalVariable", None -> decode.success(LocalVariable)
    "OperatorInvocation", None -> decode.success(OperatorInvocation)
    "DocumentationSection", None -> decode.success(DocumentationSection)
    "DocumentationParagraph", None -> decode.success(DocumentationParagraph)
    _, _ -> decode.failure(DocumentationParagraph, "TopicKind")
  }
}

pub type TopicMetadata {
  NamedTopic(topic: Topic, scope: Scope, kind: TopicKind, name: String)
  UnnamedTopic(topic: Topic, scope: Scope, kind: TopicKind)
}

fn topic_metadata_decoder() -> decode.Decoder(TopicMetadata) {
  use topic_id <- decode.field("topic_id", decode.string)
  use scope <- decode.field("scope", scope_decoder())
  use kind <- decode.then(topic_kind_decoder())
  use maybe_name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )

  let topic = Topic(id: topic_id)

  case maybe_name {
    Some(name) -> decode.success(NamedTopic(topic:, scope:, kind:, name:))
    None -> decode.success(UnnamedTopic(topic:, scope:, kind:))
  }
}

pub fn topic_metadata_name(metadata: TopicMetadata) -> String {
  case metadata {
    NamedTopic(name: name, ..) -> name
    UnnamedTopic(kind: kind, ..) -> topic_kind_to_string(kind)
  }
}

fn topic_kind_to_string(kind: TopicKind) -> String {
  case kind {
    TopicContract(contract_kind) -> contract_kind_to_string(contract_kind)
    TopicFunction(Constructor) -> "constructor"
    TopicFunction(Fallback) -> "fallback"
    TopicFunction(Receive) -> "receive"
    TopicFunction(Function) -> "function"
    TopicFunction(FreeFunction) -> "free function"
    Modifier -> "modifier"
    Event -> "event"
    TopicError -> "error"
    Struct -> "struct"
    Enum -> "enum"
    EnumMember -> "enum member"
    Constant -> "constant"
    StateVariable -> "state variable"
    LocalVariable -> "local variable"
    OperatorInvocation -> "operator invocation"
    DocumentationSection -> "documentation section"
    DocumentationParagraph -> "documentation paragraph"
  }
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

@external(javascript, "./mem_ffi.mjs", "set_contracts_promise")
fn set_contracts_promise(
  promise: promise.Promise(Result(List(TopicMetadata), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_contracts_promise")
fn read_contracts_promise() -> Result(
  promise.Promise(Result(List(TopicMetadata), snag.Snag)),
  Nil,
)

@external(javascript, "./mem_ffi.mjs", "get_contracts")
fn read_contracts() -> Result(List(TopicMetadata), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_contracts")
fn set_contracts(contracts: List(TopicMetadata)) -> Nil

fn fetch_audit_contracts() {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/" <> audit_name() <> "/contracts",
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
        decode.list(topic_metadata_decoder()),
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

fn fetch_source_text(topic: Topic) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
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

pub fn with_source_text(topic: Topic, callback) {
  case read_source_text(topic.id) {
    Ok(source_text) -> {
      callback(Ok(source_text))
      Nil
    }
    Error(_) -> {
      let promise = case read_source_text_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_source_text(topic)
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

@external(javascript, "./mem_ffi.mjs", "set_topic_metadata_promise")
fn set_topic_metadata_promise(
  topic_id: String,
  promise: promise.Promise(Result(TopicMetadata, snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_topic_metadata_promise")
fn read_topic_metadata_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(TopicMetadata, snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_topic_metadata")
fn read_topic_metadata(topic_id: String) -> Result(TopicMetadata, snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_topic_metadata")
fn set_topic_metadata(topic_id: String, metadata: TopicMetadata) -> Nil

fn fetch_topic_metadata(topic: Topic) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/metadata/"
      <> topic.id,
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let metadata =
    decode.run(resp.body, topic_metadata_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(metadata)
}

pub fn with_topic_metadata(topic: Topic, callback) {
  case read_topic_metadata(topic.id) {
    Ok(metadata) -> {
      callback(Ok(metadata))
      Nil
    }
    Error(_) -> {
      let promise = case read_topic_metadata_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_topic_metadata(topic)
          set_topic_metadata_promise(topic.id, promise)
          promise
        }
      }

      promise.await(promise, fn(metadata) {
        case metadata {
          Ok(metadata) -> {
            set_topic_metadata(topic.id, metadata)
          }
          Error(_) -> Nil
        }
        callback(metadata)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}
