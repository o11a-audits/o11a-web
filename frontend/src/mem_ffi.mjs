import { Result$Ok, Result$Error, List } from "./gleam.mjs";

let audit_name;

export function set_audit_name(name) {
  audit_name = name;
}

export function get_audit_name() {
  if (!audit_name) {
    return Result$Error();
  }
  return Result$Ok(audit_name);
}

// =============================================================================
// App Elements
// =============================================================================

let app_element;

export function set_app_element(element) {
  app_element = element;
}

export function get_app_element() {
  if (!app_element) {
    return Result$Error();
  }
  return Result$Ok(app_element);
}

let topic_view_container;

export function set_topic_view_container(element) {
  topic_view_container = element;
}

export function get_topic_view_container() {
  if (!topic_view_container) {
    return Result$Error();
  }
  return Result$Ok(topic_view_container);
}

// =============================================================================
// Data Requests
// =============================================================================

let contracts_promise;

export function set_contracts_promise(promise) {
  contracts_promise = promise;
}

export function get_contracts_promise() {
  if (!contracts_promise) {
    return Result$Error();
  }
  return Result$Ok(contracts_promise);
}

let contracts;

export function set_contracts(val) {
  contracts = val;
}

export function get_contracts() {
  if (!contracts) {
    return Result$Error();
  }
  return Result$Ok(contracts);
}

let documents_promise;

export function set_documents_promise(promise) {
  documents_promise = promise;
}

export function get_documents_promise() {
  if (!documents_promise) {
    return Result$Error();
  }
  return Result$Ok(documents_promise);
}

let documents;

export function set_documents(val) {
  documents = val;
}

export function get_documents() {
  if (!documents) {
    return Result$Error();
  }
  return Result$Ok(documents);
}

let source_text_dict = {};

let source_text_promises = {};

export function set_source_text_promise(topic_id, promise) {
  source_text_promises[topic_id] = promise;
}

export function get_source_text_promise(topic_id) {
  if (!source_text_promises[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(source_text_promises[topic_id]);
}

export function get_source_text(topic_id) {
  if (!source_text_dict[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(source_text_dict[topic_id]);
}

export function set_source_text(topic_id, text) {
  source_text_dict[topic_id] = text;
}

// =============================================================================
// History Entries
// =============================================================================

let history_entries = {};

export function set_history_entry(id, entry) {
  history_entries[id] = entry;
}

export function get_history_entry(id) {
  let entry = history_entries[id];
  if (!entry) {
    return Result$Error();
  }
  return Result$Ok(entry);
}

let current_history_entry_id = null;

export function set_current_history_entry_id(id) {
  current_history_entry_id = id;
}

export function get_current_history_entry_id() {
  if (!current_history_entry_id) {
    return Result$Error();
  }
  return Result$Ok(current_history_entry_id);
}

// =============================================================================
// Contracts Modal
// =============================================================================

let contracts_modal_state = null;

export function get_contracts_modal_state() {
  if (!contracts_modal_state) {
    return Result$Error();
  }
  return Result$Ok(contracts_modal_state);
}

export function set_contracts_modal_state(state) {
  contracts_modal_state = state;
}

// =============================================================================
// Documents Modal
// =============================================================================

let documents_modal_state = null;

export function get_documents_modal_state() {
  if (!documents_modal_state) {
    return Result$Error();
  }
  return Result$Ok(documents_modal_state);
}

export function set_documents_modal_state(state) {
  documents_modal_state = state;
}

let context = null;

export function get_context() {
  return context;
}

export function set_context(ctx) {
  context = ctx;
}

let topic_metadata_dict = {};

let topic_metadata_promises = {};

export function set_topic_metadata_promise(topic_id, promise) {
  topic_metadata_promises[topic_id] = promise;
}

export function get_topic_metadata_promise(topic_id) {
  if (!topic_metadata_promises[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_metadata_promises[topic_id]);
}

export function get_topic_metadata(topic_id) {
  if (!topic_metadata_dict[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_metadata_dict[topic_id]);
}

export function set_topic_metadata(topic_id, metadata) {
  topic_metadata_dict[topic_id] = metadata;
}

// Topic view management
let topic_views = {};
let active_topic_view_id = null;

export function get_topic_view(entry_id) {
  if (!topic_views[entry_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_views[entry_id]);
}

export function set_topic_view(entry_id, view) {
  topic_views[entry_id] = view;
}

export function get_active_topic_view_id() {
  if (!active_topic_view_id) {
    return Result$Error();
  }
  return Result$Ok(active_topic_view_id);
}

export function set_active_topic_view_id(id) {
  active_topic_view_id = id;
}

// Active view elements (transient DOM elements for the currently displayed view)
let active_view_elements = null;

export function get_active_view_elements() {
  if (!active_view_elements) {
    return Result$Error();
  }
  return Result$Ok(active_view_elements);
}

export function set_active_view_elements(elements) {
  active_view_elements = elements;
}

// =============================================================================
// Topic View
// =============================================================================

let history_container;

export function set_history_container(container) {
  history_container = container;
}

export function get_history_container() {
  if (!history_container) {
    return Result$Error();
  }
  return Result$Ok(history_container);
}

let current_child_topic_index = 0;

export function get_current_child_topic_index() {
  return current_child_topic_index;
}

export function set_current_child_topic_index(index) {
  current_child_topic_index = index;
}

// =============================================================================
// In Scope Files
// =============================================================================

let in_scope_files_promise;

export function set_in_scope_files_promise(promise) {
  in_scope_files_promise = promise;
}

export function get_in_scope_files_promise() {
  if (!in_scope_files_promise) {
    return Result$Error();
  }
  return Result$Ok(in_scope_files_promise);
}

let in_scope_files;

export function set_in_scope_files(val) {
  in_scope_files = val;
}

export function get_in_scope_files() {
  if (!in_scope_files) {
    return Result$Error();
  }
  return Result$Ok(in_scope_files);
}

// =============================================================================
// Comments
// =============================================================================

let topic_comments_dict = {};
let topic_comments_promises = {};

export function set_topic_comments_promise(topic_id, promise) {
  topic_comments_promises[topic_id] = promise;
}

export function get_topic_comments_promise(topic_id) {
  if (!topic_comments_promises[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_comments_promises[topic_id]);
}

export function get_topic_comments(topic_id) {
  if (!topic_comments_dict[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_comments_dict[topic_id]);
}

export function set_topic_comments(topic_id, val) {
  topic_comments_dict[topic_id] = val;
}

let topic_info_comments_dict = {};
let topic_info_comments_promises = {};

export function set_topic_info_comments_promise(topic_id, promise) {
  topic_info_comments_promises[topic_id] = promise;
}

export function get_topic_info_comments_promise(topic_id) {
  if (!topic_info_comments_promises[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_info_comments_promises[topic_id]);
}

export function get_topic_info_comments(topic_id) {
  if (!topic_info_comments_dict[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_info_comments_dict[topic_id]);
}

export function set_topic_info_comments(topic_id, val) {
  topic_info_comments_dict[topic_id] = val;
}

let comment_thread_dict = {};
let comment_thread_promises = {};

export function set_comment_thread_promise(topic_id, promise) {
  comment_thread_promises[topic_id] = promise;
}

export function get_comment_thread_promise(topic_id) {
  if (!comment_thread_promises[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(comment_thread_promises[topic_id]);
}

export function get_comment_thread(topic_id) {
  if (!comment_thread_dict[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(comment_thread_dict[topic_id]);
}

export function set_comment_thread(topic_id, val) {
  comment_thread_dict[topic_id] = val;
}

let comments_by_type_dict = {};
let comments_by_type_promises = {};

export function set_comments_by_type_promise(comment_type, promise) {
  comments_by_type_promises[comment_type] = promise;
}

export function get_comments_by_type_promise(comment_type) {
  if (!comments_by_type_promises[comment_type]) {
    return Result$Error();
  }
  return Result$Ok(comments_by_type_promises[comment_type]);
}

export function get_comments_by_type(comment_type) {
  if (!comments_by_type_dict[comment_type]) {
    return Result$Error();
  }
  return Result$Ok(comments_by_type_dict[comment_type]);
}

export function set_comments_by_type(comment_type, val) {
  comments_by_type_dict[comment_type] = val;
}

let mentions_dict = {};
let mentions_promises = {};

export function set_mentions_promise(topic_id, promise) {
  mentions_promises[topic_id] = promise;
}

export function get_mentions_promise(topic_id) {
  if (!mentions_promises[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(mentions_promises[topic_id]);
}

export function get_mentions(topic_id) {
  if (!mentions_dict[topic_id]) {
    return Result$Error();
  }
  return Result$Ok(mentions_dict[topic_id]);
}

export function set_mentions(topic_id, val) {
  mentions_dict[topic_id] = val;
}

// =============================================================================
// Comment Status
// =============================================================================

let comment_status_dict = {};
let comment_status_promises = {};

export function set_comment_status_promise(comment_topic_id, promise) {
  comment_status_promises[comment_topic_id] = promise;
}

export function get_comment_status_promise(comment_topic_id) {
  if (!comment_status_promises[comment_topic_id]) {
    return Result$Error();
  }
  return Result$Ok(comment_status_promises[comment_topic_id]);
}

export function get_comment_status(comment_topic_id) {
  if (!comment_status_dict[comment_topic_id]) {
    return Result$Error();
  }
  return Result$Ok(comment_status_dict[comment_topic_id]);
}

export function set_comment_status(comment_topic_id, val) {
  comment_status_dict[comment_topic_id] = val;
}

// =============================================================================
// Votes
// =============================================================================

let vote_summary_dict = {};
let vote_summary_promises = {};

export function set_vote_summary_promise(comment_topic_id, promise) {
  vote_summary_promises[comment_topic_id] = promise;
}

export function get_vote_summary_promise(comment_topic_id) {
  if (!vote_summary_promises[comment_topic_id]) {
    return Result$Error();
  }
  return Result$Ok(vote_summary_promises[comment_topic_id]);
}

export function get_vote_summary(comment_topic_id) {
  if (!vote_summary_dict[comment_topic_id]) {
    return Result$Error();
  }
  return Result$Ok(vote_summary_dict[comment_topic_id]);
}

export function set_vote_summary(comment_topic_id, val) {
  vote_summary_dict[comment_topic_id] = val;
}

let unvoted_dict = {};
let unvoted_promises = {};

export function set_unvoted_promise(user_id, promise) {
  unvoted_promises[user_id] = promise;
}

export function get_unvoted_promise(user_id) {
  if (!unvoted_promises[user_id]) {
    return Result$Error();
  }
  return Result$Ok(unvoted_promises[user_id]);
}

export function get_unvoted(user_id) {
  if (!unvoted_dict[user_id]) {
    return Result$Error();
  }
  return Result$Ok(unvoted_dict[user_id]);
}

export function set_unvoted(user_id, val) {
  unvoted_dict[user_id] = val;
}

// =============================================================================
// URL Management
// =============================================================================

export function replace_url(url) {
  window.history.replaceState(null, "", url);
}
