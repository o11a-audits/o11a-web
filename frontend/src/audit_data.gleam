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

pub type AnnotatedBlockBranch {
  TrueBranch
  FalseBranch
}

pub type AnnotatedBlockKind {
  AnnotatedBlockIf(branch: AnnotatedBlockBranch)
  AnnotatedBlockFor
  AnnotatedBlockWhile
  AnnotatedBlockDoWhile
  AnnotatedBlockUnchecked
  AnnotatedBlockInlineAssembly
}

pub type AnnotatedBlockInfo {
  AnnotatedBlockInfo(topic: Topic, kind: AnnotatedBlockKind)
}

pub type ContainingBlockLayer {
  ContainingBlockLayer(
    block: Topic,
    control_flow: option.Option(AnnotatedBlockInfo),
  )
}

pub type Scope {
  Global
  Container(container: String)
  Component(container: String, component: Topic)
  Member(
    container: String,
    component: Topic,
    member: Topic,
    signature_container: option.Option(Topic),
  )
  ContainingBlock(
    container: String,
    component: Topic,
    member: Topic,
    containing_blocks: List(ContainingBlockLayer),
  )
}

fn annotated_block_kind_decoder() -> decode.Decoder(AnnotatedBlockKind) {
  use kind_str <- decode.then(decode.string)
  case kind_str {
    "if_true" -> decode.success(AnnotatedBlockIf(branch: TrueBranch))
    "if_false" -> decode.success(AnnotatedBlockIf(branch: FalseBranch))
    "for" -> decode.success(AnnotatedBlockFor)
    "while" -> decode.success(AnnotatedBlockWhile)
    "do_while" -> decode.success(AnnotatedBlockDoWhile)
    "unchecked" -> decode.success(AnnotatedBlockUnchecked)
    "inline_assembly" -> decode.success(AnnotatedBlockInlineAssembly)
    _ -> decode.failure(AnnotatedBlockFor, "AnnotatedBlockKind")
  }
}

fn annotated_block_info_decoder() -> decode.Decoder(AnnotatedBlockInfo) {
  use topic_id <- decode.field("topic", decode.string)
  use kind <- decode.field("kind", annotated_block_kind_decoder())
  decode.success(AnnotatedBlockInfo(topic: Topic(id: topic_id), kind: kind))
}

fn containing_block_layer_decoder() -> decode.Decoder(ContainingBlockLayer) {
  use block_id <- decode.field("block", decode.string)
  use control_flow <- decode.optional_field(
    "control_flow",
    None,
    decode.optional(annotated_block_info_decoder()),
  )
  decode.success(ContainingBlockLayer(
    block: Topic(id: block_id),
    control_flow: control_flow,
  ))
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
  use containing_blocks <- decode.optional_field(
    "containing_blocks",
    [],
    decode.list(containing_block_layer_decoder()),
  )
  use maybe_signature_container <- decode.optional_field(
    "signature_container",
    None,
    decode.optional(decode.string),
  )

  case scope_type, maybe_container, maybe_component, maybe_member {
    "Global", None, None, None -> {
      decode.success(Global)
    }
    "Container", Some(container), None, None -> {
      decode.success(Container(container: container))
    }
    "Component", Some(container), Some(component), None -> {
      decode.success(Component(
        container: container,
        component: Topic(id: component),
      ))
    }
    "Member", Some(container), Some(component), Some(member) -> {
      decode.success(Member(
        container: container,
        component: Topic(id: component),
        member: Topic(id: member),
        signature_container: option.map(maybe_signature_container, fn(id) {
          Topic(id: id)
        }),
      ))
    }
    "ContainingBlock", Some(container), Some(component), Some(member) -> {
      decode.success(ContainingBlock(
        container: container,
        component: Topic(id: component),
        member: Topic(id: member),
        containing_blocks: containing_blocks,
      ))
    }
    _, _, _, _ -> decode.failure(Container(container: ""), "Scope")
  }
}

pub fn is_in_scope(scope, in_scope_files in_scope_files) {
  case scope {
    Global -> True
    Container(container)
    | Component(container:, ..)
    | Member(container:, ..)
    | ContainingBlock(container:, ..) -> {
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
    ContainingBlock(containing_blocks:, ..) ->
      case list.last(containing_blocks) {
        Ok(layer) -> Some(layer.block)
        Error(_) -> None
      }
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
    | Container(..), ContainingBlock(member:, ..)
    -> Some(member)

    // From Member or Component or ContainingBlock scope, try to get the
    // last containing block from the target
    Component(..), ContainingBlock(containing_blocks:, ..)
    | Member(..), ContainingBlock(containing_blocks:, ..)
    | ContainingBlock(..), ContainingBlock(containing_blocks:, ..)
    -> {
      case list.last(containing_blocks) {
        Ok(layer) -> Some(layer.block)
        Error(_) -> None
      }
    }

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

pub type SourceChild {
  SourceChildReference(reference: ReferenceEntry)
  SourceChildAnnotatedBlock(
    annotation: AnnotatedBlockInfo,
    children: List(SourceChild),
    has_sibling_branch: Bool,
  )
}

pub type NestedSourceContext {
  NestedSourceContext(subscope: Topic, children: List(SourceChild))
}

pub type SourceContext {
  SourceContext(
    scope: Topic,
    is_in_scope: Bool,
    scope_references: List(ReferenceEntry),
    nested_references: List(NestedSourceContext),
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
  SemanticBlock
  Break
  Continue
  Emit
  InlineAssembly
  Placeholder
  Return
  Revert
  Try
  UncheckedBlock
  Reference
  MutableReference
  Signature
  DocumentationHeading
  DocumentationParagraph
  DocumentationSentence
  DocumentationCodeBlock
  DocumentationList
  DocumentationBlockQuote
  DocumentationInlineCode
  Literal
  Other
}

pub type ControlFlowStatementKind {
  ControlFlowStatementIf
  ControlFlowStatementFor
  ControlFlowStatementWhile
  ControlFlowStatementDoWhile
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

fn source_child_decoder() -> decode.Decoder(SourceChild) {
  use child_type <- decode.field("child_type", decode.string)
  case child_type {
    "reference" -> {
      use reference <- decode.field("reference", reference_entry_decoder())
      decode.success(SourceChildReference(reference:))
    }
    "annotated_block" -> {
      use annotation <- decode.field(
        "annotation",
        annotated_block_info_decoder(),
      )
      use children <- decode.optional_field(
        "children",
        [],
        decode.list(source_child_decoder()),
      )
      use has_sibling_branch <- decode.optional_field(
        "has_sibling_branch",
        False,
        decode.bool,
      )
      decode.success(SourceChildAnnotatedBlock(
        annotation:,
        children:,
        has_sibling_branch:,
      ))
    }
    _ ->
      decode.failure(
        SourceChildReference(
          reference: ProjectReference(reference_topic: Topic(id: "")),
        ),
        "SourceChild",
      )
  }
}

fn nested_source_context_decoder() -> decode.Decoder(NestedSourceContext) {
  use subscope_id <- decode.field("subscope", decode.string)
  use children <- decode.optional_field(
    "children",
    [],
    decode.list(source_child_decoder()),
  )
  decode.success(NestedSourceContext(
    subscope: Topic(id: subscope_id),
    children:,
  ))
}

fn source_context_decoder() -> decode.Decoder(SourceContext) {
  use scope_id <- decode.field("scope", decode.string)
  use is_in_scope <- decode.field("is_in_scope", decode.bool)
  use scope_references <- decode.field(
    "scope_references",
    decode.list(reference_entry_decoder()),
  )
  use nested_references <- decode.field(
    "nested_references",
    decode.list(nested_source_context_decoder()),
  )
  decode.success(SourceContext(
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
    "SemanticBlock" -> decode.success(SemanticBlock)
    "Break" -> decode.success(Break)
    "Continue" -> decode.success(Continue)
    "Emit" -> decode.success(Emit)
    "InlineAssembly" -> decode.success(InlineAssembly)
    "Placeholder" -> decode.success(Placeholder)
    "Return" -> decode.success(Return)
    "Revert" -> decode.success(Revert)
    "Try" -> decode.success(Try)
    "UncheckedBlock" -> decode.success(UncheckedBlock)
    "Reference" -> decode.success(Reference)
    "MutableReference" -> decode.success(MutableReference)
    "Signature" -> decode.success(Signature)
"DocumentationHeading" -> decode.success(DocumentationHeading)
    "DocumentationParagraph" -> decode.success(DocumentationParagraph)
    "DocumentationSentence" -> decode.success(DocumentationSentence)
    "DocumentationCodeBlock" -> decode.success(DocumentationCodeBlock)
    "DocumentationList" -> decode.success(DocumentationList)
    "DocumentationBlockQuote" -> decode.success(DocumentationBlockQuote)
    "DocumentationInlineCode" -> decode.success(DocumentationInlineCode)
    "Literal" -> decode.success(Literal)
    "Other" -> decode.success(Other)
    _ -> decode.failure(Other, "UnnamedTopicKind")
  }
}

fn control_flow_statement_kind_decoder() -> decode.Decoder(
  ControlFlowStatementKind,
) {
  use kind_str <- decode.field("kind", decode.string)

  case kind_str {
    "If" -> decode.success(ControlFlowStatementIf)
    "For" -> decode.success(ControlFlowStatementFor)
    "While" -> decode.success(ControlFlowStatementWhile)
    "DoWhile" -> decode.success(ControlFlowStatementDoWhile)
    _ -> decode.failure(ControlFlowStatementIf, "ControlFlowStatementKind")
  }
}

pub type TopicMetadata {
  NamedTopic(
    topic: Topic,
    scope: Scope,
    kind: NamedTopicKind,
    name: String,
    visibility: NamedTopicVisibility,
    is_mutable: Bool,
    mutations: List(Topic),
    ancestors: List(Topic),
    descendants: List(Topic),
    relatives: List(Topic),
  )
  UnnamedTopic(topic: Topic, scope: Scope, kind: UnnamedTopicKind)
  ControlFlow(
    topic: Topic,
    scope: Scope,
    kind: ControlFlowStatementKind,
    condition: Topic,
  )
  TitledTopic(
    topic: Topic,
    scope: Scope,
    kind: TitledTopicKind,
    title: String,
  )
  CommentTopic(
    topic: Topic,
    scope: Scope,
    author_id: Int,
    comment_type: CommentType,
    target_topic: Topic,
    created_at: String,
    mentioned_topics: List(Topic),
  )
  Feature(
    topic: Topic,
    name: String,
    description: String,
    author_id: Int,
    created_at: String,
  )
  Requirement(
    topic: Topic,
    description: String,
    feature_topic: Topic,
    author_id: Int,
    created_at: String,
  )
  Threat(
    topic: Topic,
    description: String,
    feature_topic: Topic,
    author_id: Int,
    created_at: String,
    severity: String,
  )
  Invariant(
    topic: Topic,
    description: String,
    threat_topic: Topic,
    author_id: Int,
    created_at: String,
    severity: String,
  )
  Documentation(topic: Topic, scope: Scope, is_technical: Bool)
}

pub type ConversationEntryKind {
  CommentEntry
  MentionEntry
}

pub type ConversationEntry {
  ConversationEntry(topic_id: String, kind: ConversationEntryKind, html: String)
}

fn conversation_entry_kind_decoder() -> decode.Decoder(ConversationEntryKind) {
  use kind_str <- decode.then(decode.string)
  case kind_str {
    "comment" -> decode.success(CommentEntry)
    "mention" -> decode.success(MentionEntry)
    _ -> decode.failure(CommentEntry, "ConversationEntryKind")
  }
}

fn conversation_entry_decoder() -> decode.Decoder(ConversationEntry) {
  use topic_id <- decode.field("topic_id", decode.string)
  use kind <- decode.field("kind", conversation_entry_kind_decoder())
  use html <- decode.field("html", decode.string)
  decode.success(ConversationEntry(topic_id:, kind:, html:))
}

fn conversation_response_decoder() -> decode.Decoder(List(ConversationEntry)) {
  use entries <- decode.field(
    "entries",
    decode.list(conversation_entry_decoder()),
  )
  decode.success(entries)
}

fn topic_metadata_decoder() -> decode.Decoder(TopicMetadata) {
  use topic_type <- decode.field("type", decode.string)
  use topic_id <- decode.field("topic_id", decode.string)

  let topic = Topic(id: topic_id)

  case topic_type {
    "feature" -> {
      use name <- decode.field("name", decode.string)
      use description <- decode.field("description", decode.string)
      use author_id <- decode.field("author_id", decode.int)
      use created_at <- decode.field("created_at", decode.string)
      decode.success(Feature(
        topic:,
        name:,
        description:,
        author_id:,
        created_at:,
      ))
    }
    "requirement" -> {
      use description <- decode.field("description", decode.string)
      use feature_topic_id <- decode.field("feature_topic", decode.string)
      use author_id <- decode.field("author_id", decode.int)
      use created_at <- decode.field("created_at", decode.string)
      decode.success(Requirement(
        topic:,
        description:,
        feature_topic: Topic(id: feature_topic_id),
        author_id:,
        created_at:,
      ))
    }
    "threat" -> {
      use description <- decode.field("description", decode.string)
      use feature_topic_id <- decode.field("feature_topic", decode.string)
      use author_id <- decode.field("author_id", decode.int)
      use created_at <- decode.field("created_at", decode.string)
      use severity <- decode.field("severity", decode.string)
      decode.success(Threat(
        topic:,
        description:,
        feature_topic: Topic(id: feature_topic_id),
        author_id:,
        created_at:,
        severity:,
      ))
    }
    "invariant" -> {
      use description <- decode.field("description", decode.string)
      use threat_topic_id <- decode.field("threat_topic", decode.string)
      use author_id <- decode.field("author_id", decode.int)
      use created_at <- decode.field("created_at", decode.string)
      use severity <- decode.field("severity", decode.string)
      decode.success(Invariant(
        topic:,
        description:,
        threat_topic: Topic(id: threat_topic_id),
        author_id:,
        created_at:,
        severity:,
      ))
    }
    "named" -> {
      use scope <- decode.field("scope", scope_decoder())
      use name <- decode.field("name", decode.string)
      use kind <- decode.then(named_topic_kind_decoder())
      use visibility <- decode.then(named_topic_visibility_decoder())
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
      decode.success(NamedTopic(
        topic:,
        scope:,
        kind:,
        name:,
        visibility:,
        is_mutable:,
        mutations: list.map(mutation_ids, Topic),
        ancestors: list.map(ancestor_ids, Topic),
        descendants: list.map(descendant_ids, Topic),
        relatives: list.map(relative_ids, Topic),
      ))
    }
    "titled" -> {
      use scope <- decode.field("scope", scope_decoder())
      use title <- decode.field("title", decode.string)
      use kind <- decode.then(titled_topic_kind_decoder())
      decode.success(TitledTopic(topic:, scope:, kind:, title:))
    }
    "control_flow" -> {
      use scope <- decode.field("scope", scope_decoder())
      use kind <- decode.then(control_flow_statement_kind_decoder())
      use condition_id <- decode.field("condition", decode.string)
      decode.success(ControlFlow(
        topic:,
        scope:,
        kind:,
        condition: Topic(id: condition_id),
      ))
    }
    "CommentTopic" -> {
      use scope <- decode.field("scope", scope_decoder())
      use author_id <- decode.field("author_id", decode.int)
      use comment_type <- decode.field("comment_type", comment_type_decoder())
      use target_topic_id <- decode.field("target_topic", decode.string)
      use created_at <- decode.field("created_at", decode.string)
      use mentioned_topic_ids <- decode.field(
        "mentioned_topics",
        decode.list(decode.string),
      )
      decode.success(CommentTopic(
        topic:,
        scope:,
        author_id:,
        comment_type:,
        target_topic: Topic(id: target_topic_id),
        created_at:,
        mentioned_topics: list.map(mentioned_topic_ids, Topic),
      ))
    }
    "documentation" -> {
      use scope <- decode.field("scope", scope_decoder())
      use is_technical <- decode.field("is_technical", decode.bool)
      decode.success(Documentation(topic:, scope:, is_technical:))
    }
    _ -> {
      use scope <- decode.field("scope", scope_decoder())
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
    ControlFlow(topic:, ..) -> topic.id
    CommentTopic(topic:, ..) -> topic.id
    Feature(name:, ..) -> name
    Requirement(topic:, ..) -> topic.id
    Threat(topic:, ..) -> topic.id
    Invariant(topic:, ..) -> topic.id
    Documentation(topic:, ..) -> topic.id
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

@external(javascript, "./mem_ffi.mjs", "set_features_promise")
fn set_features_promise(
  promise: promise.Promise(Result(List(TopicMetadata), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_features_promise")
fn read_features_promise() -> Result(
  promise.Promise(Result(List(TopicMetadata), snag.Snag)),
  Nil,
)

@external(javascript, "./mem_ffi.mjs", "get_features")
fn read_features() -> Result(List(TopicMetadata), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_features")
fn set_features(features: List(TopicMetadata)) -> Nil

fn fetch_audit_features() {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/" <> audit_name() <> "/features",
    )

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_json_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  let features =
    decode.run(resp.body, decode.list(topic_metadata_decoder()))
    |> snag.map_error(string.inspect)

  promise.resolve(features)
}

pub fn with_audit_features(callback) {
  case read_features() {
    Ok(features) -> {
      callback(Ok(features))
      Nil
    }
    Error(_) -> {
      let promise = case read_features_promise() {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_audit_features()
          set_features_promise(promise)
          promise
        }
      }

      promise.await(promise, fn(features) {
        case features {
          Ok(features) -> set_features(features)
          Error(error) ->
            snag.layer(error, "Unable to fetch features")
            |> snag.line_print
            |> io.println_error
        }
        callback(features)

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

// --- Topic View (server-side rendered) ---

pub type TopicViewResponse {
  TopicViewResponse(
    topic_panel_html: String,
    expanded_references_panel_html: String,
    breadcrumb_html: String,
    highlight_css: String,
  )
}

fn topic_view_response_decoder() -> decode.Decoder(TopicViewResponse) {
  use topic_panel_html <- decode.field("topic_panel_html", decode.string)
  use expanded_references_panel_html <- decode.field(
    "expanded_references_panel_html",
    decode.string,
  )
  use breadcrumb_html <- decode.field("breadcrumb_html", decode.string)
  use highlight_css <- decode.field("highlight_css", decode.string)
  decode.success(TopicViewResponse(
    topic_panel_html:,
    expanded_references_panel_html:,
    breadcrumb_html:,
    highlight_css:,
  ))
}

pub fn fetch_topic_view(
  topic: Topic,
  callback: fn(Result(TopicViewResponse, snag.Snag)) -> Nil,
) -> Nil {
  let request_promise = {
    let assert Ok(req) =
      request.to(
        "http://172.18.115.78:3000/api/v1/audits/"
        <> audit_name()
        <> "/topic_view/"
        <> topic.id,
      )

    use resp <- promise.try_await(
      fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
    )
    use resp <- promise.try_await(
      fetch.read_json_body(resp)
      |> promise.map(snag.map_error(_, string.inspect)),
    )

    let result =
      decode.run(resp.body, topic_view_response_decoder())
      |> snag.map_error(string.inspect)

    promise.resolve(result)
  }

  promise.await(request_promise, fn(result) {
    callback(result)
    promise.resolve(Nil)
  })

  Nil
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

// Prefetches metadata, source text, and conversation for a topic
pub fn with_topic_data(topic: Topic, callback) {
  case
    read_topic_metadata(topic.id),
    read_source_text(topic.id),
    read_conversation(topic.id)
  {
    Ok(metadata), Ok(source_text), Ok(conversation) ->
      callback(Ok(metadata), Ok(source_text), Ok(conversation))
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

      let conversation_promise = case read_conversation_promise(topic.id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_conversation(topic.id)
          set_conversation_promise(topic.id, promise)
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

          promise.await(conversation_promise, fn(conversation) {
            case conversation {
              Ok(conversation) -> set_conversation(topic.id, conversation)
              Error(error) ->
                snag.layer(
                  error,
                  "Unable to fetch conversation for topic " <> topic.id,
                )
                |> snag.line_print
                |> io.println_error
            }

            callback(metadata, source_text, conversation)
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
  ConversationUpdated(
    audit_id: String,
    topic_id: String,
    entry: ConversationEntry,
    invalidated_thread_ids: List(String),
  )
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
    "ConversationUpdated" -> {
      use topic_id <- decode.field("topic_id", decode.string)
      use entry <- decode.field("entry", conversation_entry_decoder())
      use invalidated_thread_ids <- decode.optional_field(
        "invalidated_thread_ids",
        [],
        decode.list(decode.string),
      )
      decode.success(ConversationUpdated(
        audit_id:,
        topic_id:,
        entry:,
        invalidated_thread_ids:,
      ))
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
    _ ->
      decode.failure(
        ConversationUpdated(
          audit_id: "",
          topic_id: "",
          entry: ConversationEntry(topic_id: "", kind: CommentEntry, html: ""),
          invalidated_thread_ids: [],
        ),
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

fn comment_created_response_decoder() -> decode.Decoder(String) {
  use id <- decode.field("comment_topic_id", decode.string)
  decode.success(id)
}

fn comment_list_response_decoder() -> decode.Decoder(List(String)) {
  use ids <- decode.field("comment_topic_ids", decode.list(decode.string))
  decode.success(ids)
}

// --- Conversation: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_conversation_promise")
fn set_conversation_promise(
  topic_id: String,
  promise: promise.Promise(Result(List(ConversationEntry), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_conversation_promise")
fn read_conversation_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(List(ConversationEntry), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_conversation")
fn read_conversation(
  topic_id: String,
) -> Result(List(ConversationEntry), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_conversation")
fn set_conversation(topic_id: String, val: List(ConversationEntry)) -> Nil

// --- Thread HTML Cache: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "get_thread_html")
fn read_thread_html(topic_id: String) -> Result(String, snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_thread_html")
fn set_thread_html(topic_id: String, val: String) -> Nil

@external(javascript, "./mem_ffi.mjs", "clear_thread_html")
fn clear_thread_html(topic_id: String) -> Nil

// --- Comments by type: FFI Declarations ---

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

// --- Thread: Fetch Functions ---

fn fetch_thread(topic_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/thread/"
      <> topic_id,
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

fn refetch_thread(topic_id: String) -> Nil {
  let request_promise = fetch_thread(topic_id)
  promise.await(request_promise, fn(result) {
    case result {
      Ok(html) -> set_thread_html(topic_id, html)
      Error(error) ->
        snag.layer(error, "Unable to refetch thread for " <> topic_id)
        |> snag.line_print
        |> io.println_error
    }
    promise.resolve(Nil)
  })
  Nil
}

pub fn get_cached_thread_html(topic_id: String) -> Result(String, snag.Snag) {
  read_thread_html(topic_id)
}

pub fn with_thread_html(
  topic_id: String,
  callback: fn(Result(String, snag.Snag)) -> Nil,
) {
  case read_thread_html(topic_id) {
    Ok(html) -> {
      callback(Ok(html))
      Nil
    }
    Error(_) -> {
      let request_promise = fetch_thread(topic_id)
      promise.await(request_promise, fn(result) {
        case result {
          Ok(html) -> set_thread_html(topic_id, html)
          Error(_) -> Nil
        }
        callback(result)
        promise.resolve(Nil)
      })
      Nil
    }
  }
}

// --- Conversation: Fetch Functions ---

fn fetch_conversation(topic_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/conversation/"
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
    decode.run(resp.body, conversation_response_decoder())
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

pub fn with_conversation(
  topic_id: String,
  callback: fn(Result(List(ConversationEntry), snag.Snag)) -> Nil,
) {
  case read_conversation(topic_id) {
    Ok(entries) -> {
      callback(Ok(entries))
      Nil
    }
    Error(_) -> {
      let promise = case read_conversation_promise(topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_conversation(topic_id)
          set_conversation_promise(topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(entries) {
        case entries {
          Ok(entries) -> {
            set_conversation(topic_id, entries)
            // Populate thread cache from conversation entries
            list.each(entries, fn(entry) {
              set_thread_html(entry.topic_id, entry.html)
            })
          }
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch conversation for topic " <> topic_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(entries)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

// --- Documentation: Types ---

// --- Documentation: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_topic_requirements_promise")
fn set_topic_requirements_promise(
  topic_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_topic_requirements_promise")
fn read_topic_requirements_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_topic_requirements")
fn read_topic_requirements(topic_id: String) -> Result(List(String), Nil)

@external(javascript, "./mem_ffi.mjs", "set_topic_requirements")
fn set_topic_requirements(topic_id: String, val: List(String)) -> Nil

@external(javascript, "./mem_ffi.mjs", "set_documentation_html_promise")
fn set_documentation_html_promise(
  key: String,
  promise: promise.Promise(Result(String, snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_documentation_html_promise")
fn read_documentation_html_promise(
  key: String,
) -> Result(promise.Promise(Result(String, snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_documentation_html")
fn read_documentation_html(key: String) -> Result(String, Nil)

@external(javascript, "./mem_ffi.mjs", "set_documentation_html")
fn set_documentation_html(key: String, val: String) -> Nil

// --- Documentation: Fetch Functions ---

fn fetch_topic_requirements(topic_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/requirements/topic/"
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
    decode.run(resp.body, decode.list(decode.string))
    |> snag.map_error(string.inspect)

  promise.resolve(result)
}

fn fetch_documentation_html(feature_topics: List(String)) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/documentation",
    )

  let body =
    json.object([
      #("feature_topics", json.array(feature_topics, json.string)),
    ])

  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(json.to_string(body))

  use resp <- promise.try_await(
    fetch.send(req) |> promise.map(snag.map_error(_, string.inspect)),
  )
  use resp <- promise.try_await(
    fetch.read_text_body(resp)
    |> promise.map(snag.map_error(_, string.inspect)),
  )

  promise.resolve(Ok(resp.body))
}

// --- Documentation: with_* Functions ---

pub fn with_topic_requirements(
  topic_id: String,
  callback: fn(Result(List(String), snag.Snag)) -> Nil,
) {
  case read_topic_requirements(topic_id) {
    Ok(requirements) -> {
      callback(Ok(requirements))
      Nil
    }
    Error(_) -> {
      let promise = case read_topic_requirements_promise(topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_topic_requirements(topic_id)
          set_topic_requirements_promise(topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(requirements) {
        case requirements {
          Ok(requirements) -> set_topic_requirements(topic_id, requirements)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch requirements for topic " <> topic_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(requirements)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

pub fn with_documentation_html(
  feature_topics: List(String),
  callback: fn(Result(String, snag.Snag)) -> Nil,
) {
  let key = string.join(feature_topics, ",")
  case read_documentation_html(key) {
    Ok(html) -> {
      callback(Ok(html))
      Nil
    }
    Error(_) -> {
      let promise = case read_documentation_html_promise(key) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_documentation_html(feature_topics)
          set_documentation_html_promise(key, promise)
          promise
        }
      }

      promise.await(promise, fn(result) {
        case result {
          Ok(html) -> set_documentation_html(key, html)
          Error(error) ->
            snag.layer(error, "Unable to fetch documentation HTML")
            |> snag.line_print
            |> io.println_error
        }
        callback(result)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

// --- Feature Children: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_feature_requirements_promise")
fn set_feature_requirements_promise(
  feature_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_feature_requirements_promise")
fn read_feature_requirements_promise(
  feature_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_feature_requirements")
fn read_feature_requirements(feature_id: String) -> Result(List(String), Nil)

@external(javascript, "./mem_ffi.mjs", "set_feature_requirements")
fn set_feature_requirements(feature_id: String, val: List(String)) -> Nil

@external(javascript, "./mem_ffi.mjs", "set_feature_threats_promise")
fn set_feature_threats_promise(
  feature_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_feature_threats_promise")
fn read_feature_threats_promise(
  feature_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_feature_threats")
fn read_feature_threats(feature_id: String) -> Result(List(String), Nil)

@external(javascript, "./mem_ffi.mjs", "set_feature_threats")
fn set_feature_threats(feature_id: String, val: List(String)) -> Nil

// --- Feature Children: Fetch Functions ---

fn fetch_feature_requirements(feature_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/features/"
      <> feature_id
      <> "/requirements",
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

fn fetch_feature_threats(feature_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/features/"
      <> feature_id
      <> "/threats",
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

// --- Feature Children: with_* Functions ---

pub fn with_feature_requirements(
  feature_id: String,
  callback: fn(Result(List(String), snag.Snag)) -> Nil,
) {
  case read_feature_requirements(feature_id) {
    Ok(requirements) -> {
      callback(Ok(requirements))
      Nil
    }
    Error(_) -> {
      let promise = case read_feature_requirements_promise(feature_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_feature_requirements(feature_id)
          set_feature_requirements_promise(feature_id, promise)
          promise
        }
      }

      promise.await(promise, fn(requirements) {
        case requirements {
          Ok(requirements) ->
            set_feature_requirements(feature_id, requirements)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch requirements for feature " <> feature_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(requirements)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

pub fn with_feature_threats(
  feature_id: String,
  callback: fn(Result(List(String), snag.Snag)) -> Nil,
) {
  case read_feature_threats(feature_id) {
    Ok(threats) -> {
      callback(Ok(threats))
      Nil
    }
    Error(_) -> {
      let promise = case read_feature_threats_promise(feature_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_feature_threats(feature_id)
          set_feature_threats_promise(feature_id, promise)
          promise
        }
      }

      promise.await(promise, fn(threats) {
        case threats {
          Ok(threats) -> set_feature_threats(feature_id, threats)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch threats for feature " <> feature_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(threats)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

// --- Threat Children: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_threat_invariants_promise")
fn set_threat_invariants_promise(
  threat_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_threat_invariants_promise")
fn read_threat_invariants_promise(
  threat_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_threat_invariants")
fn read_threat_invariants(threat_id: String) -> Result(List(String), Nil)

@external(javascript, "./mem_ffi.mjs", "set_threat_invariants")
fn set_threat_invariants(threat_id: String, val: List(String)) -> Nil

// --- Threat Children: Fetch Functions ---

fn fetch_threat_invariants(threat_id: String) {
  let assert Ok(req) =
    request.to(
      "http://172.18.115.78:3000/api/v1/audits/"
      <> audit_name()
      <> "/threats/"
      <> threat_id
      <> "/invariants",
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

// --- Threat Children: with_* Functions ---

pub fn with_threat_invariants(
  threat_id: String,
  callback: fn(Result(List(String), snag.Snag)) -> Nil,
) {
  case read_threat_invariants(threat_id) {
    Ok(invariants) -> {
      callback(Ok(invariants))
      Nil
    }
    Error(_) -> {
      let promise = case read_threat_invariants_promise(threat_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_threat_invariants(threat_id)
          set_threat_invariants_promise(threat_id, promise)
          promise
        }
      }

      promise.await(promise, fn(invariants) {
        case invariants {
          Ok(invariants) -> set_threat_invariants(threat_id, invariants)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch invariants for threat " <> threat_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(invariants)

        promise.resolve(Nil)
      })

      Nil
    }
  }
}

// --- Info Comments: FFI Declarations ---

@external(javascript, "./mem_ffi.mjs", "set_topic_info_comments_promise")
fn set_topic_info_comments_promise(
  topic_id: String,
  promise: promise.Promise(Result(List(String), snag.Snag)),
) -> Nil

@external(javascript, "./mem_ffi.mjs", "get_topic_info_comments_promise")
fn read_topic_info_comments_promise(
  topic_id: String,
) -> Result(promise.Promise(Result(List(String), snag.Snag)), Nil)

@external(javascript, "./mem_ffi.mjs", "get_topic_info_comments")
fn read_topic_info_comments(topic_id: String) -> Result(List(String), snag.Snag)

@external(javascript, "./mem_ffi.mjs", "set_topic_info_comments")
fn set_topic_info_comments(topic_id: String, val: List(String)) -> Nil

// --- Info Comments: Fetch + Public API ---

fn fetch_topic_info_comments(topic_id: String) {
  promise.new(fn(resolve) {
    with_conversation(topic_id, fn(conversation_result) {
      resolve(
        result.map(conversation_result, fn(entries) {
          list.filter_map(entries, fn(entry) {
            case entry.kind {
              CommentEntry ->
                case read_topic_metadata(entry.topic_id) {
                  Ok(CommentTopic(comment_type: Info, ..)) -> Ok(entry.topic_id)
                  _ -> Error(Nil)
                }
              MentionEntry -> Error(Nil)
            }
          })
        }),
      )
    })
  })
}

pub fn with_topic_info_comments(topic_id: String, callback) {
  case read_topic_info_comments(topic_id) {
    Ok(info_comments) -> {
      callback(Ok(info_comments))
      Nil
    }
    Error(_) -> {
      let promise = case read_topic_info_comments_promise(topic_id) {
        Ok(promise) -> promise
        Error(Nil) -> {
          let promise = fetch_topic_info_comments(topic_id)
          set_topic_info_comments_promise(topic_id, promise)
          promise
        }
      }

      promise.await(promise, fn(info_comments) {
        case info_comments {
          Ok(info_comments) -> set_topic_info_comments(topic_id, info_comments)
          Error(error) ->
            snag.layer(
              error,
              "Unable to fetch info comments for topic " <> topic_id,
            )
            |> snag.line_print
            |> io.println_error
        }
        callback(info_comments)
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
  callback: fn(Result(String, snag.Snag)) -> Nil,
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

  let request_promise = {
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

  promise.await(request_promise, fn(result) {
    callback(result)
    promise.resolve(Nil)
  })
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

pub fn connect_comment_ws(
  on_conversation_updated on_conversation_updated: fn(String) -> Nil,
) -> Nil {
  let url =
    "ws://172.18.115.78:3000/api/v1/audits/" <> audit_name() <> "/comments/ws"

  ws_connect(url, handle_comment_event(_, on_conversation_updated))
}

fn handle_comment_event(
  raw: String,
  on_conversation_updated: fn(String) -> Nil,
) -> Nil {
  case json.parse(raw, comment_event_decoder()) {
    Ok(event) -> process_comment_event(event, on_conversation_updated)
    Error(_) -> {
      io.println_error("Failed to decode WebSocket comment event")
      Nil
    }
  }
}

fn process_comment_event(
  event: CommentEvent,
  on_conversation_updated: fn(String) -> Nil,
) -> Nil {
  case event {
    ConversationUpdated(audit_id:, topic_id:, entry:, invalidated_thread_ids:) -> {
      // Append entry to cached conversation list
      case read_conversation(topic_id) {
        Ok(entries) -> set_conversation(topic_id, list.append(entries, [entry]))
        Error(_) -> Nil
      }
      // Cache the new entry's thread HTML
      set_thread_html(entry.topic_id, entry.html)
      // Invalidate and refetch stale threads
      list.each(invalidated_thread_ids, fn(thread_id) {
        clear_thread_html(thread_id)
        refetch_thread(thread_id)
      })
      case audit_id == audit_name() {
        True -> on_conversation_updated(topic_id)
        False -> Nil
      }
      Nil
    }
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
  }
}
