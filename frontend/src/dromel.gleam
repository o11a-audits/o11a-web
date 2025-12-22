//// dromel - A chainable DOM manipulation library built on plinth
////
//// This module provides a more ergonomic, chainable API over plinth's browser APIs
//// while maintaining full compatibility with plinth types.

import gleam/dynamic
import gleam/dynamic/decode
import plinth/browser/document
import plinth/browser/element
import plinth/browser/event

// ============================================================================
// Re-export plinth types for convenience
// ============================================================================

pub type Element =
  element.Element

pub type Event(t) =
  event.Event(t)

// ============================================================================
// Element Creation
// ============================================================================

pub fn new_div() -> Element {
  document.create_element("div")
}

pub fn new_span() -> Element {
  document.create_element("span")
}

pub fn new_input() -> Element {
  document.create_element("input")
}

pub fn new(tag_name: String) -> Element {
  document.create_element(tag_name)
}

// ============================================================================
// Attributes (Chainable)
// ============================================================================

pub fn set_attribute(elem: Element, attribute: String, value: String) -> Element {
  element.set_attribute(elem, attribute, value)
  elem
}

pub fn get_attribute(elem: Element, attribute: String) -> Result(String, Nil) {
  element.get_attribute(elem, attribute)
}

pub fn set_id(elem: Element, id: String) -> Element {
  set_attribute(elem, "id", id)
}

pub fn set_class(elem: Element, class: String) -> Element {
  set_attribute(elem, "class", class)
}

pub fn set_type(elem: Element, type_: String) -> Element {
  set_attribute(elem, "type", type_)
}

pub fn set_placeholder(elem: Element, placeholder: String) -> Element {
  set_attribute(elem, "placeholder", placeholder)
}

// ============================================================================
// Styles (Chainable)
// ============================================================================

pub fn set_style(elem: Element, style: String) -> Element {
  element.set_attribute(elem, "style", style)
  elem
}

pub fn add_style(elem: Element, style: String) -> Element {
  let existing_style = case element.get_attribute(elem, "style") {
    Ok(style) -> style <> "; "
    Error(_) -> ""
  }
  element.set_attribute(elem, "style", existing_style <> style)
  elem
}

// ============================================================================
// Content (Chainable)
// ============================================================================

pub fn set_inner_html(elem: Element, html: String) -> Element {
  element.set_inner_html(elem, html)
  elem
}

pub fn set_inner_text(elem: Element, text: String) -> Element {
  element.set_inner_text(elem, text)
  elem
}

// ============================================================================
// DOM Manipulation (Chainable - returns parent for chaining)
// ============================================================================

pub fn append_child(parent: Element, child: Element) -> Element {
  element.append_child(parent, child)
  parent
}

pub fn remove(elem: Element) -> Element {
  element.remove(elem)
  elem
}

// ============================================================================
// Element Properties
// ============================================================================

pub fn value(elem: Element) -> Result(String, Nil) {
  element.value(elem)
}

pub fn focus(elem: Element) -> Element {
  element.focus(elem)
  elem
}

// ============================================================================
// Event Handling (Chainable - returns element for chaining)
// ============================================================================

pub fn add_event_listener(
  elem: Element,
  event_type: String,
  handler: fn(Event(t)) -> Nil,
) -> Element {
  element.add_event_listener(elem, event_type, handler)
  elem
}

// ============================================================================
// DOM Querying (Non-chainable - returns Result)
// ============================================================================

pub fn query_selector(selector: String) -> Result(Element, Nil) {
  document.query_selector(selector)
}

// ============================================================================
// Element Utilities
// ============================================================================

pub fn cast(target: dynamic.Dynamic) -> Result(Element, decode.DecodeError) {
  element.cast(target)
}
