import { Result$Ok, Result$Error } from "./gleam.mjs";

export function element_query_selector(element, selector) {
  let val = element.querySelector(selector);
  if (val) {
    return Result$Ok(val);
  }
  return Result$Error();
}

export function element_query_selector_all(element, selector) {
  return Array.from(element.querySelectorAll(selector));
}

export function get_scroll_top(element) {
  return element.scrollTop;
}

export function set_scroll_top(element, value) {
  element.scrollTop = value;
}

export function get_inner_html(element) {
  return element.innerHTML;
}

export function parent_element(element) {
  let parent = element.parentElement;
  if (parent) {
    return Result$Ok(parent);
  }
  return Result$Error();
}

export function class_list(element) {
  return Array.from(element.classList);
}

export function client_width(element) {
  return element.clientWidth;
}

export function scroll_width(element) {
  return element.scrollWidth;
}

export function first_child(element) {
  let child = element.firstElementChild;
  if (child) {
    return Result$Ok(child);
  }
  return Result$Error();
}

export function remove_attribute(element, attribute) {
  element.removeAttribute(attribute);
  return element;
}
