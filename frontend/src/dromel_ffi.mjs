import { Result$Ok, Result$Error } from "./gleam.mjs";

export function element_query_selector(element, selector) {
  let val = element.querySelector(selector);
  if (val) {
    return Result$Ok(val);
  }
  return Result$Error();
}

export function element_query_selector_all(element, selector) {
  return element.querySelectorAll(selector);
}

export function get_scroll_top(element) {
  return element.scrollTop;
}

export function set_scroll_top(element, value) {
  element.scrollTop = value;
}
