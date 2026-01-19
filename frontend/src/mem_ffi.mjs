import { Result$Ok, Result$Error } from "./gleam.mjs";

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

// Focus context tracking
let focus_context = "default"; // "default" | "input"

export function set_input_context() {
  focus_context = "input";
}

export function clear_input_context() {
  focus_context = "default";
}

export function is_in_input_context() {
  return focus_context === "input";
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

export function clear_active_view_elements() {
  active_view_elements = null;
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
// URL Management
// =============================================================================

export function replace_url(url) {
  window.history.replaceState(null, "", url);
}
