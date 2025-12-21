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

export function set_navigation_node(id, node) {
  navigation_history[id] = node;
}

export function get_navigation_node(id) {
  let node = navigation_history[id];
  if (!node) {
    return Result$Error();
  }
  return Result$Ok(node);
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

export function clear_contracts_modal_state() {
  contracts_modal_state = null;
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
