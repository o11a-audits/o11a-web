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

let navigation_history = {};

export function set_navigation_entry(id, entry) {
  navigation_history[id] = entry;
}

export function get_navigation_entry(id) {
  let entry = navigation_history[id];
  if (!entry) {
    return Result$Error();
  }
  return Result$Ok(entry);
}

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
let active_view_entry_id = null;

export function get_topic_view(entry_id) {
  if (!topic_views[entry_id]) {
    return Result$Error();
  }
  return Result$Ok(topic_views[entry_id]);
}

export function set_topic_view(entry_id, view) {
  topic_views[entry_id] = view;
}

export function get_active_view_entry_id() {
  if (!active_view_entry_id) {
    return Result$Error();
  }
  return Result$Ok(active_view_entry_id);
}

export function set_active_view_entry_id(entry_id) {
  active_view_entry_id = entry_id;
}
