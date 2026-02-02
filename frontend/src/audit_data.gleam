import dromel
import gleam/dynamic/decode
import gleam/fetch
import gleam/http/request
import gleam/io
import gleam/javascript/promise
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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
      case window.pathname() |> string.split("/") {
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
          Ok(contracts) -> set_contracts(contracts)
          Error(error) ->
            snag.layer(error, "Unable to fetch contracts")
            |> snag.line_print
            |> io.println_error
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
  Global
  Container(container: String)
  Component(container: String, component: Topic)
  Member(container: String, component: Topic, member: Topic)
  SemanticBlock(
    container: String,
    component: Topic,
    member: Topic,
    semantic_block: Topic,
  )
}

fn scope_decoder() -> decode.Decoder(Scope) {
  use scope_type <- decode.field("scope_type", decode.string)
  use maybe_container <- decode.optional_field(
    "container",
    None,
    decode.optional(decode.string),
  )
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
  use maybe_semantic_block <- decode.optional_field(
    "semantic_block",
    None,
    decode.optional(decode.string),
  )

  case
    scope_type,
    maybe_container,
    maybe_component,
    maybe_member,
    maybe_semantic_block
  {
    "Global", None, None, None, None -> {
      decode.success(Global)
    }
    "Container", Some(container), None, None, None -> {
      decode.success(Container(container: container))
    }
    "Component", Some(container), Some(component), None, None -> {
      decode.success(Component(
        container: container,
        component: Topic(id: component),
      ))
    }
    "Member", Some(container), Some(component), Some(member), None -> {
      decode.success(Member(
        container: container,
        component: Topic(id: component),
        member: Topic(id: member),
      ))
    }
    "SemanticBlock",
      Some(container),
      Some(component),
      Some(member),
      Some(semantic_block)
    -> {
      decode.success(SemanticBlock(
        container: container,
        component: Topic(id: component),
        member: Topic(id: member),
        semantic_block: Topic(id: semantic_block),
      ))
    }
    _, _, _, _, _ -> decode.failure(Container(container: ""), "Scope")
  }
}

pub fn is_in_scope(scope, in_scope_files in_scope_files) {
  case scope {
    Global -> True
    Container(container)
    | Component(container:, ..)
    | Member(container:, ..)
    | SemanticBlock(container:, ..) -> {
      list.contains(in_scope_files, container)
    }
  }
}

/// Get the parent scope one level up, returning None if already at Component level or above
pub fn parent_topic(scope: Scope) -> option.Option(Topic) {
  case scope {
    Global -> None
    Container(_) -> None
    Component(component:, ..) -> Some(component)
    Member(member:, ..) -> Some(member)
    SemanticBlock(semantic_block:, ..) -> Some(semantic_block)
  }
}

/// Given current scope and target scope, get the next topic to navigate down
/// towards target.
/// Returns None if already at or past target scope level
pub fn child_scope_towards(
  current_scope: Scope,
  target_scope: Scope,
) -> option.Option(Topic) {
  echo current_scope as "current_scope"
  echo target_scope as "target_scope"
  case current_scope, target_scope {
    // From Component (Container scope), try to get the Member
    Container(..), Member(member:, ..)
    | Container(..), SemanticBlock(member:, ..)
    -> Some(member)

    // From Member (Component scope), try to get the SemanticBlock
    Component(..), SemanticBlock(semantic_block:, ..) -> Some(semantic_block)

    // From first-level SemanticBlock (Member scope), try to get the next SemanticBlock
    Member(..), SemanticBlock(semantic_block:, ..) -> Some(semantic_block)

    // From SemanticBlock, try to get the next SemanticBlock
    SemanticBlock(..), SemanticBlock(semantic_block:, ..) ->
      Some(semantic_block)

    _, _ -> None
  }
}

pub type FunctionKind {
  Constructor
  Fallback
  Receive
  Function
  FreeFunction
}

pub type VariableMutability {
  Constant
  Immutable
}

pub type NamedTopicVisibility {
  Public
  Private
  Internal
  External
}

pub type NamedTopicKind {
  TopicContract(ContractKind)
  TopicFunction(FunctionKind)
  Modifier
  Event
  TopicError
  Struct
  Enum
  EnumMember
  StateVariable(VariableMutability)
  LocalVariable
  Builtin
}

pub type NestedReferenceGroup {
  NestedReferenceGroup(subscope: Topic, references: List(Topic))
}

pub type ReferenceGroup {
  ReferenceGroup(
    scope: Topic,
    is_in_scope: Bool,
    scope_references: List(Topic),
    nested_references: List(NestedReferenceGroup),
  )
}

pub type TitledTopicKind {
  DocumentationSection
}

pub type UnnamedTopicKind {
  VariableMutation
  Arithmetic
  Comparison
  Logical
  Bitwise
  Conditional
  FunctionCall
  TypeConversion
  StructConstruction
  NewExpression
  UnnamedSemanticBlock
  Break
  Continue
  DoWhile
  Emit
  For
  If
  InlineAssembly
  Placeholder
  Return
  Revert
  Try
  UncheckedBlock
  While
  Reference
  MutableReference
  Signature
  DocumentationRoot
  DocumentationHeading
  DocumentationParagraph
  DocumentationSentence
  DocumentationCodeBlock
  DocumentationList
  DocumentationBlockQuote
  Other
}

fn named_topic_kind_decoder() -> decode.Decoder(NamedTopicKind) {
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
    "StateVariable", Some("Constant") -> decode.success(StateVariable(Constant))
    "StateVariable", Some("Immutable") ->
      decode.success(StateVariable(Immutable))
    "LocalVariable", None -> decode.success(LocalVariable)
    "Builtin", None -> decode.success(Builtin)
    _, _ -> decode.failure(Builtin, "NamedTopicKind")
  }
}

fn titled_topic_kind_decoder() -> decode.Decoder(TitledTopicKind) {
  use kind_str <- decode.field("kind", decode.string)

  case kind_str {
    "DocumentationSection" -> decode.success(DocumentationSection)
    _ -> decode.failure(DocumentationSection, "TitledTopicKind")
  }
}

fn named_topic_visibility_decoder() -> decode.Decoder(NamedTopicVisibility) {
  use visibility_str <- decode.field("visibility", decode.string)

  case visibility_str {
    "Public" -> decode.success(Public)
    "Private" -> decode.success(Private)
    "Internal" -> decode.success(Internal)
    "External" -> decode.success(External)
    _ -> decode.failure(Public, "NamedTopicVisibility")
  }
}

fn nested_reference_group_decoder() -> decode.Decoder(NestedReferenceGroup) {
  use subscope_id <- decode.field("subscope", decode.string)
  use reference_ids <- decode.field("references", decode.list(decode.string))
  decode.success(NestedReferenceGroup(
    subscope: Topic(id: subscope_id),
    references: list.map(reference_ids, Topic),
  ))
}

fn reference_group_decoder() -> decode.Decoder(ReferenceGroup) {
  use scope_id <- decode.field("scope", decode.string)
  use is_in_scope <- decode.field("is_in_scope", decode.bool)
  use scope_reference_ids <- decode.field(
    "scope_references",
    decode.list(decode.string),
  )
  use nested_references <- decode.field(
    "nested_references",
    decode.list(nested_reference_group_decoder()),
  )
  decode.success(ReferenceGroup(
    scope: Topic(id: scope_id),
    is_in_scope:,
    scope_references: list.map(scope_reference_ids, Topic),
    nested_references:,
  ))
}

fn unnamed_topic_kind_decoder() -> decode.Decoder(UnnamedTopicKind) {
  use kind_str <- decode.field("kind", decode.string)

  case kind_str {
    "VariableMutation" -> decode.success(VariableMutation)
    "Arithmetic" -> decode.success(Arithmetic)
    "Comparison" -> decode.success(Comparison)
    "Logical" -> decode.success(Logical)
    "Bitwise" -> decode.success(Bitwise)
    "Conditional" -> decode.success(Conditional)
    "FunctionCall" -> decode.success(FunctionCall)
    "TypeConversion" -> decode.success(TypeConversion)
    "StructConstruction" -> decode.success(StructConstruction)
    "NewExpression" -> decode.success(NewExpression)
    "SemanticBlock" -> decode.success(UnnamedSemanticBlock)
    "Break" -> decode.success(Break)
    "Continue" -> decode.success(Continue)
    "DoWhile" -> decode.success(DoWhile)
    "Emit" -> decode.success(Emit)
    "For" -> decode.success(For)
    "If" -> decode.success(If)
    "InlineAssembly" -> decode.success(InlineAssembly)
    "Placeholder" -> decode.success(Placeholder)
    "Return" -> decode.success(Return)
    "Revert" -> decode.success(Revert)
    "Try" -> decode.success(Try)
    "UncheckedBlock" -> decode.success(UncheckedBlock)
    "While" -> decode.success(While)
    "Reference" -> decode.success(Reference)
    "MutableReference" -> decode.success(MutableReference)
    "Signature" -> decode.success(Signature)
    "DocumentationRoot" -> decode.success(DocumentationRoot)
    "DocumentationHeading" -> decode.success(DocumentationHeading)
    "DocumentationParagraph" -> decode.success(DocumentationParagraph)
    "DocumentationSentence" -> decode.success(DocumentationSentence)
    "DocumentationCodeBlock" -> decode.success(DocumentationCodeBlock)
    "DocumentationList" -> decode.success(DocumentationList)
    "DocumentationBlockQuote" -> decode.success(DocumentationBlockQuote)
    "Other" -> decode.success(Other)
    _ -> decode.failure(Other, "UnnamedTopicKind")
  }
}

pub type TopicMetadata {
  NamedTopic(
    topic: Topic,
    scope: Scope,
    kind: NamedTopicKind,
    name: String,
    visibility: NamedTopicVisibility,
    references: List(ReferenceGroup),
    expanded_references: List(ReferenceGroup),
    is_mutable: Bool,
    mutations: List(Topic),
    ancestors: List(Topic),
    descendants: List(Topic),
    relatives: List(Topic),
    mentions: List(ReferenceGroup),
  )
  TitledTopic(topic: Topic, scope: Scope, kind: TitledTopicKind, title: String)
  UnnamedTopic(topic: Topic, scope: Scope, kind: UnnamedTopicKind)
}

fn topic_metadata_decoder() -> decode.Decoder(TopicMetadata) {
  use topic_id <- decode.field("topic_id", decode.string)
  use scope <- decode.field("scope", scope_decoder())
  use maybe_name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use maybe_title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )

  let topic = Topic(id: topic_id)

  case maybe_name, maybe_title {
    Some(name), None -> {
      use kind <- decode.then(named_topic_kind_decoder())
      use visibility <- decode.then(named_topic_visibility_decoder())
      use references <- decode.field(
        "references",
        decode.list(reference_group_decoder()),
      )
      use expanded_references <- decode.field(
        "expanded_references",
        decode.list(reference_group_decoder()),
      )
      use is_mutable <- decode.field("is_mutable", decode.bool)
      use mutation_ids <- decode.field("mutations", decode.list(decode.string))
      use ancestor_ids <- decode.field("ancestors", decode.list(decode.string))
      use descendant_ids <- decode.field(
        "descendants",
        decode.list(decode.string),
      )
      use relative_ids <- decode.field("relatives", decode.list(decode.string))
      use mentions <- decode.field(
        "mentions",
        decode.list(reference_group_decoder()),
      )
      decode.success(NamedTopic(
        topic:,
        scope:,
        kind:,
        name:,
        visibility:,
        references:,
        expanded_references:,
        is_mutable:,
        mutations: list.map(mutation_ids, Topic),
        ancestors: list.map(ancestor_ids, Topic),
        descendants: list.map(descendant_ids, Topic),
        relatives: list.map(relative_ids, Topic),
        mentions:,
      ))
    }
    None, Some(title) -> {
      use kind <- decode.then(titled_topic_kind_decoder())
      decode.success(TitledTopic(topic:, scope:, kind:, title:))
    }
    _, _ -> {
      use kind <- decode.then(unnamed_topic_kind_decoder())
      decode.success(UnnamedTopic(topic:, scope:, kind:))
    }
  }
}

pub fn topic_metadata_name(metadata: TopicMetadata) -> String {
  case metadata {
    NamedTopic(name:, ..) -> name
    TitledTopic(title:, ..) -> title
    UnnamedTopic(topic:, ..) -> topic.id
  }
}

pub fn topic_metadata_highlighted_name(metadata: TopicMetadata) -> String {
  let kw = fn(text) { "<span class=\"keyword\">" <> text <> "</span>" }
  let visibility_kw = fn(visibility) {
    case visibility {
      Public -> kw("pub") <> " "
      Private -> kw("priv") <> " "
      Internal -> kw("int") <> " "
      External -> kw("ext") <> " "
    }
  }

  let highlighted_name = case metadata {
    NamedTopic(name:, kind:, visibility:, is_mutable:, ..) ->
      case kind, is_mutable {
        TopicContract(contract_kind), _ ->
          kw(contract_kind_to_keyword(contract_kind))
          <> " <span class=\"contract\">"
          <> name
          <> "</span>"
        TopicFunction(Function), _ | TopicFunction(FreeFunction), _ ->
          visibility_kw(visibility)
          <> kw("fn")
          <> " <span class=\"function\">"
          <> name
          <> "</span>"
        TopicFunction(Receive), _ -> visibility_kw(visibility) <> kw("receive")
        TopicFunction(Fallback), _ ->
          visibility_kw(visibility) <> kw("fallback")
        TopicFunction(Constructor), _ -> kw("constructor")
        Modifier, _ ->
          kw("mod") <> " <span class=\"modifier\">" <> name <> "</span>"
        Event, _ ->
          visibility_kw(visibility)
          <> kw("event")
          <> " <span class=\"event\">"
          <> name
          <> "</span>"
        TopicError, _ ->
          visibility_kw(visibility)
          <> kw("error")
          <> " <span class=\"error\">"
          <> name
          <> "</span>"
        Struct, _ ->
          visibility_kw(visibility)
          <> kw("struct")
          <> " <span class=\"struct\">"
          <> name
          <> "</span>"
        Enum, _ ->
          visibility_kw(visibility)
          <> kw("enum")
          <> " <span class=\"enum\">"
          <> name
          <> "</span>"
        EnumMember, _ -> "<span class=\"enum-value\">" <> name <> "</span>"
        StateVariable(_), True ->
          visibility_kw(visibility)
          <> "<span class=\"mutable-state-variable\">"
          <> name
          <> "</span>"
        StateVariable(Constant), False ->
          visibility_kw(visibility)
          <> kw("const")
          <> " <span class=\"constant\">"
          <> name
          <> "</span>"
        StateVariable(Immutable), False ->
          visibility_kw(visibility)
          <> kw("immutable")
          <> " <span class=\"immutable-state-variable\">"
          <> name
          <> "</span>"
        LocalVariable, True ->
          "<span class=\"mutable-local-variable\">" <> name <> "</span>"
        LocalVariable, False ->
          "<span class=\"local-variable\">" <> name <> "</span>"
        Builtin, _ -> "<span class=\"global\">" <> name <> "</span>"
      }
    TitledTopic(title:, kind:, ..) ->
      case kind {
        DocumentationSection -> "<span>" <> title <> "</span>"
      }
    UnnamedTopic(kind:, ..) ->
      case kind {
        VariableMutation -> "<span class=\"keyword\">MutationStatement</span>"
        Arithmetic -> "<span class=\"operator\">ArithmeticExpression</span>"
        Comparison -> "<span class=\"operator\">ComparisonExpression</span>"
        Logical -> "<span class=\"operator\">BooleanExpression</span>"
        Bitwise -> "<span class=\"operator\">BitwiseExpression</span>"
        Conditional -> "<span class=\"keyword\">ConditionalStatement</span>"
        FunctionCall -> "<span class=\"function\">FunctionCall</span>"
        TypeConversion -> "<span class=\"operator\">TypeConversion</span>"
        StructConstruction -> "<span class=\"struct\">StructConstruction</span>"
        NewExpression -> "<span class=\"keyword\">NewExpression</span>"
        UnnamedSemanticBlock -> "<span class=\"block\">Block</span>"
        Break -> "<span class=\"keyword\">BreakStatement</span>"
        Continue -> "<span class=\"keyword\">ContinueStatement</span>"
        DoWhile -> "<span class=\"keyword\">DoWhileStatement</span>"
        Emit -> "<span class=\"keyword\">EmitStatement</span>"
        For -> "<span class=\"keyword\">ForStatement</span>"
        If -> "<span class=\"keyword\">IfStatement</span>"
        InlineAssembly -> "<span class=\"keyword\">InlineAssembly</span>"
        Placeholder -> "<span class=\"keyword\">PlaceholderStatement</span>"
        Return -> "<span class=\"keyword\">ReturnStatement</span>"
        Revert -> "<span class=\"keyword\">RevertStatement</span>"
        Try -> "<span class=\"keyword\">TryStatement</span>"
        UncheckedBlock -> "<span class=\"keyword\">UncheckedBlock</span>"
        While -> "<span class=\"keyword\">WhileStatement</span>"
        Reference -> "<span class=\"identifier\">Reference</span>"
        MutableReference -> "<span class=\"identifier\">MutableReference</span>"
        Signature -> "<span class=\"identifier\">Signature</span>"
        DocumentationRoot -> "<span>Documentation</span>"
        DocumentationHeading -> "<span>DocumentationHeading</span>"
        DocumentationParagraph -> "<span>DocumentationParagraph</span>"
        DocumentationSentence -> "<span>DocumentationSentence</span>"
        DocumentationCodeBlock -> "<span>DocumentationCodeBlock</span>"
        DocumentationList -> "<span>DocumentationList</span>"
        DocumentationBlockQuote -> "<span>DocumentationBlockQuote</span>"
        Other -> "<span>Other</span>"
      }
  }

  "<code>" <> highlighted_name <> "</code>"
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

pub fn contract_kind_to_keyword(kind: ContractKind) -> String {
  case kind {
    Contract -> "contract"
    Interface -> "interface"
    Library -> "library"
    Abstract -> "abstract"
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

@external(javascript, "./mem_ffi.mjs", "set_documents_promise")
fn set_documents_promise(
  promise: promise.Promise(Result(List(TopicMetadata), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_documents_promise")
fn read_documents_promise() -> Result(
  promise.Promise(Result(List(TopicMetadata), snag.Snag)),
  Nil,
)

@external(javascript, "./mem_ffi.mjs", "get_documents")
fn read_documents() -> Result(List(TopicMetadata), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_documents")
fn set_documents(documents: List(TopicMetadata)) -> Nil

fn fetch_audit_documents() {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/" <> audit_name() <> "/documents",
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let documents =
    decode.run(resp.body, {
      use documents <- decode.field(
        "documents",
        decode.list(topic_metadata_decoder()),
      )
      decode.success(documents)
    })
    |> snag.map_error(string.inspect)

  promise.resolve(documents)
}

pub fn with_audit_documents(callback) {
  case read_documents() {
    Ok(documents) -> {
      callback(Ok(documents))
      Nil
    }
    Error(_) -> {
      let promise = case read_documents_promise() {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_audit_documents()
          set_documents_promise(promise)
          promise
        }
      }

      promise.await(promise, fn(documents) {
        case documents {
          Ok(documents) -> set_documents(documents)
          Error(error) ->
            snag.layer(error, "Unable to fetch documents")
            |> snag.line_print
            |> io.println_error
        }
        callback(documents)

        promise.resolve(Nil)
      })

      Nil
    }
  }
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
          Ok(source_text) -> set_source_text(topic.id, source_text)
          Error(error) ->
            snag.layer(error, "Unable to fetch source text")
            |> snag.line_print
            |> io.println_error
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
    Ok(metadata) -> callback(Ok(metadata))
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
          Ok(metadata) -> set_topic_metadata(topic.id, metadata)
          Error(error) ->
            snag.layer(error, "Unable to fetch metadata for topic " <> topic.id)
            |> snag.line_print
            |> io.println_error
        }
        callback(metadata)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

// Fetches both metadata and source text for a topic
pub fn with_topic_data(topic: Topic, callback) {
  case read_topic_metadata(topic.id), read_source_text(topic.id) {
    Ok(metadata), Ok(source_text) -> callback(Ok(metadata), Ok(source_text))
    _, _ -> {
      let metadata_promise = case read_topic_metadata_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_topic_metadata(topic)
          set_topic_metadata_promise(topic.id, promise)
          promise
        }
      }

      let source_text_promise = case read_source_text_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_source_text(topic)
          set_source_text_promise(topic.id, promise)
          promise
        }
      }

      promise.await(metadata_promise, fn(metadata) {
        case metadata {
          Ok(metadata) -> set_topic_metadata(topic.id, metadata)
          Error(error) ->
            snag.layer(error, "Unable to fetch metadata for topic " <> topic.id)
            |> snag.line_print
            |> io.println_error
        }

        promise.await(source_text_promise, fn(source_text) {
          case source_text {
            Ok(source_text) -> set_source_text(topic.id, source_text)
            Error(error) ->
              snag.layer(
                error,
                "Unable to fetch source text for topic " <> topic.id,
              )
              |> snag.line_print
              |> io.println_error
          }

          callback(metadata, source_text)
          promise.resolve(Nil)
        })
        promise.resolve(Nil)
      })

      Nil
    }
  }
}

@external(javascript, "./mem_ffi.mjs", "set_in_scope_files_promise")
fn set_in_scope_files_promise(
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_in_scope_files_promise")
fn read_in_scope_files_promise() -> Result(
  promise.Promise(Result(List(String), snag.Snag)),
  Nil,
)

@external(javascript, "./mem_ffi.mjs", "get_in_scope_files")
fn read_in_scope_files() -> Result(List(String), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_in_scope_files")
fn set_in_scope_files(files: List(String)) -> Nil

fn fetch_in_scope_files() {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/in_scope_files",
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let in_scope_files =
    decode.run(resp.body, {
      use files <- decode.field("in_scope_files", decode.list(decode.string))
      decode.success(files)
    })
    |> snag.map_error(string.inspect)

  promise.resolve(in_scope_files)
}

pub fn with_is_in_scope(scope, callback) {
  case read_in_scope_files() {
    Ok(files) -> {
      is_in_scope(scope, files)
      |> callback
      Nil
    }
    Error(_) -> {
      let promise = case read_in_scope_files_promise() {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_in_scope_files()
          set_in_scope_files_promise(promise)
          promise
        }
      }

      promise.await(promise, fn(files) {
        case files {
          Ok(files) -> set_in_scope_files(files)
          Error(error) ->
            snag.layer(error, "Unable to fetch in-scope files")
            |> snag.line_print
            |> io.println_error
        }

        is_in_scope(scope, files |> result.unwrap([]))
        |> callback

        promise.resolve(Nil)
      })

      Nil
    }
  }
}
