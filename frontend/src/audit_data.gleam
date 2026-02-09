import dromel
import gleam/dynamic/decode
import gleam/fetch
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/javascript/promise
import gleam/json
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
  Mutable
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

pub type ReferenceEntry {
  ProjectReference(reference_topic: Topic)
  ProjectReferenceWithMentions(
    reference_topic: Topic,
    mention_topics: List(Topic),
  )
  CommentMention(reference_topic: Topic, mention_topics: List(Topic))
}

pub type NestedReferenceGroup {
  NestedReferenceGroup(subscope: Topic, references: List(ReferenceEntry))
}

pub type ReferenceGroup {
  ReferenceGroup(
    scope: Topic,
    is_in_scope: Bool,
    scope_references: List(ReferenceEntry),
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
  DocumentationInlineCode
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
    "StateVariable", Some("Mutable") -> decode.success(StateVariable(Mutable))
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

fn reference_entry_decoder() -> decode.Decoder(ReferenceEntry) {
  use ref_type <- decode.field("type", decode.string)
  use reference_topic_id <- decode.field("reference_topic", decode.string)
  case ref_type {
    "project" ->
      decode.success(
        ProjectReference(reference_topic: Topic(id: reference_topic_id)),
      )
    "project_with_mentions" -> {
      use mention_ids <- decode.field(
        "mention_topics",
        decode.list(decode.string),
      )
      decode.success(ProjectReferenceWithMentions(
        reference_topic: Topic(id: reference_topic_id),
        mention_topics: list.map(mention_ids, Topic),
      ))
    }
    "comment" -> {
      use mention_ids <- decode.field(
        "mention_topics",
        decode.list(decode.string),
      )
      decode.success(CommentMention(
        reference_topic: Topic(id: reference_topic_id),
        mention_topics: list.map(mention_ids, Topic),
      ))
    }
    _ ->
      decode.failure(
        ProjectReference(reference_topic: Topic(id: "")),
        "ReferenceEntry",
      )
  }
}

fn nested_reference_group_decoder() -> decode.Decoder(NestedReferenceGroup) {
  use subscope_id <- decode.field("subscope", decode.string)
  use references <- decode.field(
    "references",
    decode.list(reference_entry_decoder()),
  )
  decode.success(NestedReferenceGroup(
    subscope: Topic(id: subscope_id),
    references:,
  ))
}

fn reference_group_decoder() -> decode.Decoder(ReferenceGroup) {
  use scope_id <- decode.field("scope", decode.string)
  use is_in_scope <- decode.field("is_in_scope", decode.bool)
  use scope_references <- decode.field(
    "scope_references",
    decode.list(reference_entry_decoder()),
  )
  use nested_references <- decode.field(
    "nested_references",
    decode.list(nested_reference_group_decoder()),
  )
  decode.success(ReferenceGroup(
    scope: Topic(id: scope_id),
    is_in_scope:,
    scope_references:,
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
    "DocumentationInlineCode" -> decode.success(DocumentationInlineCode)
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
    ancestry: List(ReferenceGroup),
    is_mutable: Bool,
    mutations: List(Topic),
    ancestors: List(Topic),
    descendants: List(Topic),
    relatives: List(Topic),
    mentions: List(ReferenceGroup),
  )
  TitledTopic(topic: Topic, scope: Scope, kind: TitledTopicKind, title: String)
  UnnamedTopic(topic: Topic, scope: Scope, kind: UnnamedTopicKind)
  CommentTopic(
    topic: Topic,
    scope: Scope,
    author_id: Int,
    comment_type: CommentType,
    target_topic: String,
    created_at: String,
    mentioned_topics: List(String),
    mentions: List(ReferenceGroup),
  )
}

fn topic_metadata_decoder() -> decode.Decoder(TopicMetadata) {
  use topic_type <- decode.field("type", decode.string)
  use topic_id <- decode.field("topic_id", decode.string)
  use scope <- decode.field("scope", scope_decoder())

  let topic = Topic(id: topic_id)

  case topic_type {
    "named" -> {
      use name <- decode.field("name", decode.string)
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
      use ancestry <- decode.field(
        "ancestry",
        decode.list(reference_group_decoder()),
      )
      use mutation_ids <- decode.optional_field(
        "mutations",
        [],
        decode.list(decode.string),
      )
      let is_mutable = case mutation_ids {
        [_, ..] -> True
        _ -> False
      }
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
        ancestry:,
        is_mutable:,
        mutations: list.map(mutation_ids, Topic),
        ancestors: list.map(ancestor_ids, Topic),
        descendants: list.map(descendant_ids, Topic),
        relatives: list.map(relative_ids, Topic),
        mentions:,
      ))
    }
    "titled" -> {
      use title <- decode.field("title", decode.string)
      use kind <- decode.then(titled_topic_kind_decoder())
      decode.success(TitledTopic(topic:, scope:, kind:, title:))
    }
    "CommentTopic" -> {
      use author_id <- decode.field("author_id", decode.int)
      use comment_type <- decode.field("comment_type", comment_type_decoder())
      use target_topic <- decode.field("target_topic", decode.string)
      use created_at <- decode.field("created_at", decode.string)
      use mentioned_topics <- decode.field(
        "mentioned_topics",
        decode.list(decode.string),
      )
      use mentions <- decode.field(
        "mentions",
        decode.list(reference_group_decoder()),
      )
      decode.success(CommentTopic(
        topic:,
        author_id:,
        comment_type:,
        target_topic:,
        created_at:,
        scope:,
        mentioned_topics:,
        mentions:,
      ))
    }
    _ -> {
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
    CommentTopic(topic:, ..) -> topic.id
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
        StateVariable(_), True | StateVariable(Mutable), _ ->
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
        DocumentationInlineCode -> "<span>DocumentationInlineCode</span>"
        Other -> "<span>Other</span>"
      }
    CommentTopic(..) -> "<span>Comment</span>"
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
  case
    read_topic_metadata(topic.id),
    read_source_text(topic.id),
    read_topic_comments(topic.id)
  {
    Ok(metadata), Ok(source_text), Ok(comments) ->
      callback(Ok(metadata), Ok(source_text), Ok(comments))
    _, _, _ -> {
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

      let comments_promise = case read_topic_comments_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_topic_comments(topic.id)
          set_topic_comments_promise(topic.id, promise)
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

          promise.await(comments_promise, fn(comments) {
            case comments {
              Ok(comments) -> set_topic_comments(topic.id, comments)
              Error(error) ->
                snag.layer(
                  error,
                  "Unable to fetch comments for topic " <> topic.id,
                )
                |> snag.line_print
                |> io.println_error
            }

            callback(metadata, source_text, comments)
            promise.resolve(Nil)
          })
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

pub fn reference_entry_topic(entry: ReferenceEntry) -> Topic {
  case entry {
    ProjectReference(reference_topic:) -> reference_topic
    ProjectReferenceWithMentions(reference_topic:, ..) -> reference_topic
    CommentMention(reference_topic:, ..) -> reference_topic
  }
}

// --- Collaborator Types ---

pub type CommentType {
  Note
  Info
  Question
  Answer
  Todo
  FindingLead
}

pub type CommentStatus {
  Active
  Hidden
  Resolved
  Unanswered
  Answered
  Unconfirmed
  Confirmed
  Rejected
}

pub type VoteValue {
  Up
  Down
}

pub type CommentStatusResponse {
  CommentStatusResponse(comment_topic_id: String, status: CommentStatus)
}

pub type CommentVoteSummary {
  CommentVoteSummary(
    comment_id: Int,
    comment_topic_id: String,
    score: Int,
    upvotes: Int,
    downvotes: Int,
    user_vote: option.Option(VoteValue),
  )
}

pub type CommentEvent {
  CommentCreated(audit_id: String, comment_topic_id: String)
  StatusUpdated(
    audit_id: String,
    comment_topic_id: String,
    status: CommentStatus,
  )
  VoteUpdated(
    audit_id: String,
    comment_topic_id: String,
    score: Int,
    upvotes: Int,
    downvotes: Int,
  )
  MentionsUpdated(
    audit_id: String,
    topic_id: String,
    mentions: List(ReferenceGroup),
  )
}

// --- Collaborator Decoders ---

fn comment_type_decoder() -> decode.Decoder(CommentType) {
  use type_str <- decode.then(decode.string)
  case type_str {
    "note" -> decode.success(Note)
    "info" -> decode.success(Info)
    "question" -> decode.success(Question)
    "answer" -> decode.success(Answer)
    "todo" -> decode.success(Todo)
    "finding_lead" -> decode.success(FindingLead)
    _ -> decode.failure(Note, "CommentType")
  }
}

fn comment_status_decoder() -> decode.Decoder(CommentStatus) {
  use status_str <- decode.then(decode.string)
  case status_str {
    "active" -> decode.success(Active)
    "hidden" -> decode.success(Hidden)
    "resolved" -> decode.success(Resolved)
    "unanswered" -> decode.success(Unanswered)
    "answered" -> decode.success(Answered)
    "unconfirmed" -> decode.success(Unconfirmed)
    "confirmed" -> decode.success(Confirmed)
    "rejected" -> decode.success(Rejected)
    _ -> decode.failure(Active, "CommentStatus")
  }
}

fn vote_value_decoder() -> decode.Decoder(VoteValue) {
  use value_str <- decode.then(decode.string)
  case value_str {
    "up" -> decode.success(Up)
    "down" -> decode.success(Down)
    _ -> decode.failure(Up, "VoteValue")
  }
}

fn comment_status_response_decoder() -> decode.Decoder(CommentStatusResponse) {
  use comment_topic_id <- decode.field("comment_topic_id", decode.string)
  use status <- decode.field("status", comment_status_decoder())
  decode.success(CommentStatusResponse(comment_topic_id:, status:))
}

fn comment_vote_summary_decoder() -> decode.Decoder(CommentVoteSummary) {
  use comment_id <- decode.field("comment_id", decode.int)
  use comment_topic_id <- decode.field("comment_topic_id", decode.string)
  use score <- decode.field("score", decode.int)
  use upvotes <- decode.field("upvotes", decode.int)
  use downvotes <- decode.field("downvotes", decode.int)
  use user_vote <- decode.optional_field(
    "user_vote",
    None,
    decode.optional(vote_value_decoder()),
  )
  decode.success(CommentVoteSummary(
    comment_id:,
    comment_topic_id:,
    score:,
    upvotes:,
    downvotes:,
    user_vote:,
  ))
}

fn comment_event_decoder() -> decode.Decoder(CommentEvent) {
  use event_type <- decode.field("type", decode.string)
  use audit_id <- decode.field("audit_id", decode.string)
  case event_type {
    "Created" -> {
      use comment_topic_id <- decode.field("comment_topic_id", decode.string)
      decode.success(CommentCreated(audit_id:, comment_topic_id:))
    }
    "StatusUpdated" -> {
      use comment_topic_id <- decode.field("comment_topic_id", decode.string)
      use status <- decode.field("status", comment_status_decoder())
      decode.success(StatusUpdated(audit_id:, comment_topic_id:, status:))
    }
    "VoteUpdated" -> {
      use comment_topic_id <- decode.field("comment_topic_id", decode.string)
      use score <- decode.field("score", decode.int)
      use upvotes <- decode.field("upvotes", decode.int)
      use downvotes <- decode.field("downvotes", decode.int)
      decode.success(VoteUpdated(
        audit_id:,
        comment_topic_id:,
        score:,
        upvotes:,
        downvotes:,
      ))
    }
    "MentionsUpdated" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      use mentions <- decode.field(
        "mentions",
        decode.list(reference_group_decoder()),
      )
      decode.success(MentionsUpdated(audit_id:, topic_id:, mentions:))
    }
    _ ->
      decode.failure(
        CommentCreated(audit_id: "", comment_topic_id: ""),
        "CommentEvent",
      )
  }
}

// --- Collaborator Encoders ---

pub fn comment_type_to_string(comment_type: CommentType) -> String {
  case comment_type {
    Note -> "note"
    Info -> "info"
    Question -> "question"
    Answer -> "answer"
    Todo -> "todo"
    FindingLead -> "finding_lead"
  }
}

pub fn comment_status_to_string(status: CommentStatus) -> String {
  case status {
    Active -> "active"
    Hidden -> "hidden"
    Resolved -> "resolved"
    Unanswered -> "unanswered"
    Answered -> "answered"
    Unconfirmed -> "unconfirmed"
    Confirmed -> "confirmed"
    Rejected -> "rejected"
  }
}

pub fn vote_value_to_string(vote: VoteValue) -> String {
  case vote {
    Up -> "up"
    Down -> "down"
  }
}

// --- Collaborator Response Decoders ---

fn comment_list_response_decoder() -> decode.Decoder(List(String)) {
  use ids <- decode.field("comment_topic_ids", decode.list(decode.string))
  decode.success(ids)
}

fn comment_created_response_decoder() -> decode.Decoder(String) {
  use id <- decode.field("comment_topic_id", decode.string)
  decode.success(id)
}

// --- Comments: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_topic_comments_promise")
fn set_topic_comments_promise(
  topic_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_topic_comments_promise")
fn read_topic_comments_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_topic_comments")
fn read_topic_comments(topic_id: String) -> Result(List(String), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_topic_comments")
fn set_topic_comments(topic_id: String, val: List(String)) -> Nil

@external(javascript, "./mem_ffi.mjs", "set_comments_by_type_promise")
fn set_comments_by_type_promise(
  comment_type: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_comments_by_type_promise")
fn read_comments_by_type_promise(
  comment_type: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_comments_by_type")
fn read_comments_by_type(
  comment_type: String,
) -> Result(List(String), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_comments_by_type")
fn set_comments_by_type(comment_type: String, val: List(String)) -> Nil

@external(javascript, "./mem_ffi.mjs", "set_mentions_promise")
fn set_mentions_promise(
  topic_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_mentions_promise")
fn read_mentions_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_mentions")
fn read_mentions(topic_id: String) -> Result(List(String), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_mentions")
fn set_mentions(topic_id: String, val: List(String)) -> Nil

// --- Comments: Fetch Functions ---

fn fetch_topic_comments(topic_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/topics/"
      <> topic_id
      <> "/comments",
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_list_response_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_topic_comments(topic_id: String, callback) {
  case read_topic_comments(topic_id) {
    Ok(comments) -> {
      callback(Ok(comments))
      Nil
    }
    Error(_) -> {
      let promise = case read_topic_comments_promise(topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_topic_comments(topic_id)
          set_topic_comments_promise(topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(comments) {
        case comments {
          Ok(comments) -> set_topic_comments(topic_id, comments)
          Error(error) ->
            snag.layer(error, "Unable to fetch comments for topic " <> topic_id)
            |> snag.line_print
            |> io.println_error
        }
        callback(comments)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

fn fetch_comments_by_type(comment_type: CommentType, status: CommentStatus) {
  let type_str = comment_type_to_string(comment_type)
  let status_str = comment_status_to_string(status)
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/comments/"
      <> type_str
      <> "/"
      <> status_str,
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_list_response_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_comments_by_type(
  comment_type: CommentType,
  status: CommentStatus,
  callback,
) {
  let cache_key =
    comment_type_to_string(comment_type)
    <> "/"
    <> comment_status_to_string(status)
  case read_comments_by_type(cache_key) {
    Ok(comments) -> {
      callback(Ok(comments))
      Nil
    }
    Error(_) -> {
      let promise = case read_comments_by_type_promise(cache_key) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_comments_by_type(comment_type, status)
          set_comments_by_type_promise(cache_key, promise)
          promise
        }
      }

      promise.await(promise, fn(comments) {
        case comments {
          Ok(comments) -> set_comments_by_type(cache_key, comments)
          Error(error) ->
            snag.layer(error, "Unable to fetch comments of type " <> cache_key)
            |> snag.line_print
            |> io.println_error
        }
        callback(comments)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

pub fn create_comment(
  topic_id: String,
  content: String,
  author_id: Int,
  comment_type: CommentType,
) {
  let body =
    json.object([
      #("topic_id", json.string(topic_id)),
      #("content", json.string(content)),
      #("author_id", json.int(author_id)),
      #("comment_type", json.string(comment_type_to_string(comment_type))),
    ])
    |> json.to_string

  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/" <> audit_name() <> "/comments",
    )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_created_response_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

fn fetch_mentions(topic_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/mentions/"
      <> topic_id,
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_list_response_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_mentions(topic_id: String, callback) {
  case read_mentions(topic_id) {
    Ok(mentions) -> {
      callback(Ok(mentions))
      Nil
    }
    Error(_) -> {
      let promise = case read_mentions_promise(topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_mentions(topic_id)
          set_mentions_promise(topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(mentions) {
        case mentions {
          Ok(mentions) -> set_mentions(topic_id, mentions)
          Error(error) ->
            snag.layer(error, "Unable to fetch mentions for topic " <> topic_id)
            |> snag.line_print
            |> io.println_error
        }
        callback(mentions)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

// --- Status: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_comment_status_promise")
fn set_comment_status_promise(
  comment_topic_id: String,
  promise: promise.Promise(Result(CommentStatusResponse, snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_comment_status_promise")
fn read_comment_status_promise(
  comment_topic_id: String,
) -> Result(promise.Promise(Result(CommentStatusResponse, snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_comment_status")
fn read_comment_status(
  comment_topic_id: String,
) -> Result(CommentStatusResponse, snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_comment_status")
fn set_comment_status(
  comment_topic_id: String,
  val: CommentStatusResponse,
) -> Nil

fn comment_numeric_id(comment_topic_id: String) -> String {
  string.drop_start(comment_topic_id, 1)
}

// --- Status: Fetch Functions ---

fn fetch_comment_status(comment_topic_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/comments/"
      <> comment_numeric_id(comment_topic_id)
      <> "/status",
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_status_response_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_comment_status(comment_topic_id: String, callback) {
  case read_comment_status(comment_topic_id) {
    Ok(status) -> {
      callback(Ok(status))
      Nil
    }
    Error(_) -> {
      let promise = case read_comment_status_promise(comment_topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_comment_status(comment_topic_id)
          set_comment_status_promise(comment_topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(status) {
        case status {
          Ok(status) -> set_comment_status(comment_topic_id, status)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch status for comment " <> comment_topic_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(status)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

pub fn update_comment_status(comment_topic_id: String, status: CommentStatus) {
  let body =
    json.object([
      #("status", json.string(comment_status_to_string(status))),
    ])
    |> json.to_string

  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/comments/"
      <> comment_numeric_id(comment_topic_id)
      <> "/status",
    )
  let req =
    req
    |> request.set_method(http.Put)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_status_response_decoder())
    |> snag.map_error(string.inspect)

  // Update cache with the new status
  case result {
    Ok(status_response) -> set_comment_status(comment_topic_id, status_response)
    Error(_) -> Nil
  }

  promise.resolve(result)
}

// --- Votes: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_vote_summary_promise")
fn set_vote_summary_promise(
  comment_topic_id: String,
  promise: promise.Promise(Result(CommentVoteSummary, snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_vote_summary_promise")
fn read_vote_summary_promise(
  comment_topic_id: String,
) -> Result(promise.Promise(Result(CommentVoteSummary, snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_vote_summary")
fn read_vote_summary(
  comment_topic_id: String,
) -> Result(CommentVoteSummary, snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_vote_summary")
fn set_vote_summary(comment_topic_id: String, val: CommentVoteSummary) -> Nil

@external(javascript, "./mem_ffi.mjs", "set_unvoted_promise")
fn set_unvoted_promise(
  user_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_unvoted_promise")
fn read_unvoted_promise(
  user_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_unvoted")
fn read_unvoted(user_id: String) -> Result(List(String), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_unvoted")
fn set_unvoted(user_id: String, val: List(String)) -> Nil

// --- Votes: Fetch Functions ---

fn fetch_unvoted(user_id: Int) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/votes/unvoted?user_id="
      <> int.to_string(user_id),
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, decode.list(decode.string))
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_unvoted(user_id: Int, callback) {
  let user_id_str = int.to_string(user_id)
  case read_unvoted(user_id_str) {
    Ok(unvoted) -> {
      callback(Ok(unvoted))
      Nil
    }
    Error(_) -> {
      let promise = case read_unvoted_promise(user_id_str) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_unvoted(user_id)
          set_unvoted_promise(user_id_str, promise)
          promise
        }
      }

      promise.await(promise, fn(unvoted) {
        case unvoted {
          Ok(unvoted) -> set_unvoted(user_id_str, unvoted)
          Error(error) ->
            snag.layer(error, "Unable to fetch unvoted comments")
            |> snag.line_print
            |> io.println_error
        }
        callback(unvoted)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

fn fetch_vote_summary(comment_topic_id: String, user_id: Int) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/votes/"
      <> comment_numeric_id(comment_topic_id)
      <> "?user_id="
      <> int.to_string(user_id),
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_vote_summary_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_vote_summary(comment_topic_id: String, user_id: Int, callback) {
  case read_vote_summary(comment_topic_id) {
    Ok(summary) -> {
      callback(Ok(summary))
      Nil
    }
    Error(_) -> {
      let promise = case read_vote_summary_promise(comment_topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_vote_summary(comment_topic_id, user_id)
          set_vote_summary_promise(comment_topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(summary) {
        case summary {
          Ok(summary) -> set_vote_summary(comment_topic_id, summary)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch vote summary for " <> comment_topic_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(summary)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

pub fn cast_vote(comment_topic_id: String, user_id: Int, vote: VoteValue) {
  let body =
    json.object([
      #("user_id", json.int(user_id)),
      #("vote", json.string(vote_value_to_string(vote))),
    ])
    |> json.to_string

  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/votes/"
      <> comment_numeric_id(comment_topic_id),
    )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_body(body)
    |> request.set_header("content-type", "application/json")

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let result =
    decode.run(resp.body, comment_vote_summary_decoder())
    |> snag.map_error(string.inspect)

  // Update cache with the new summary
  case result {
    Ok(summary) -> set_vote_summary(comment_topic_id, summary)
    Error(_) -> Nil
  }

  promise.resolve(result)
}

pub fn delete_vote(comment_topic_id: String, user_id: Int) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/votes/"
      <> comment_numeric_id(comment_topic_id)
      <> "?user_id="
      <> int.to_string(user_id),
    )
  let req =
    req
    |> request.set_method(http.Delete)
    |> request.set_body("")

  use _resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )

  promise.resolve(Ok(Nil))
}

// --- WebSocket ---

@external(javascript, "./ws_ffi.mjs", "ws_connect")
fn ws_connect(url: String, on_message: fn(String) -> Nil) -> Nil

@external(javascript, "./ws_ffi.mjs", "ws_close")
pub fn ws_close() -> Nil

pub fn connect_comment_ws() -> Nil {
  let url =
    "ws://172.18.115.78:3000/api/v1/audits/" <> audit_name() <> "/comments/ws"

  ws_connect(url, handle_comment_event)
}

fn handle_comment_event(raw: String) -> Nil {
  case json.parse(raw, comment_event_decoder()) {
    Ok(event) -> process_comment_event(event)
    Error(_) -> {
      io.println_error("Failed to decode WebSocket comment event")
      Nil
    }
  }
}

fn process_comment_event(event: CommentEvent) -> Nil {
  case event {
    CommentCreated(audit_id: _, comment_topic_id: _) -> Nil
    StatusUpdated(audit_id: _, comment_topic_id:, status:) -> {
      set_comment_status(
        comment_topic_id,
        CommentStatusResponse(comment_topic_id:, status:),
      )
      Nil
    }
    VoteUpdated(audit_id: _, comment_topic_id:, score:, upvotes:, downvotes:) -> {
      case read_vote_summary(comment_topic_id) {
        Ok(existing) ->
          set_vote_summary(
            comment_topic_id,
            CommentVoteSummary(..existing, score:, upvotes:, downvotes:),
          )
        Error(_) -> Nil
      }
      Nil
    }
    MentionsUpdated(audit_id: _, topic_id:, mentions:) -> {
      case read_topic_metadata(topic_id) {
        Ok(NamedTopic(
          topic:,
          scope:,
          kind:,
          name:,
          visibility:,
          references:,
          expanded_references:,
          ancestry:,
          is_mutable:,
          mutations:,
          ancestors:,
          descendants:,
          relatives:,
          mentions: _,
        )) ->
          set_topic_metadata(
            topic_id,
            NamedTopic(
              topic:,
              scope:,
              kind:,
              name:,
              visibility:,
              references:,
              expanded_references:,
              ancestry:,
              is_mutable:,
              mutations:,
              ancestors:,
              descendants:,
              relatives:,
              mentions:,
            ),
          )
        _ -> Nil
      }
      Nil
    }
  }
}
