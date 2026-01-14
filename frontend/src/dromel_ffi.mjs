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
