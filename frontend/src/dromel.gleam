//// dromel - A chainable DOM manipulation library built on plinth
////
//// This module provides a more ergonomic, chainable API over plinth's browser APIs
//// while maintaining full compatibility with plinth types.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/javascript/array
import gleam/list
import gleam/string
import plinth/browser/document
import plinth/browser/element
import plinth/browser/event

// ============================================================================
// Plinth types for convenience
// ============================================================================

pub type Element =
  element.Element

pub type Event(t) =
  event.Event(t)

// ============================================================================
// ElementRef
// ============================================================================

pub type ElementRef {
  Selector(selector: String)
  Class(class: String)
  Id(id: String)
}

pub fn selector(element: ElementRef) -> String {
  case element {
    Selector(selector) -> selector
    Class(class) -> "." <> class
    Id(id) -> "#" <> id
  }
}

pub fn matches_ref(
  element element: Element,
  ref element_ref: ElementRef,
) -> Bool {
  case element_ref {
    Selector(_) -> panic as "Cannot match selectors"
    Class(class) -> get_attribute(element, "class") == Ok(class)
    Id(id) -> get_attribute(element, "id") == Ok(id)
  }
}

// ============================================================================
// Data Keys
// ============================================================================

pub type DataKey {
  DataKey(key: String)
}

pub fn set_data(element: Element, key: DataKey, value: String) -> Element {
  element.set_attribute(element, "data-" <> key.key, value)
  element
}

pub fn get_data(element: Element, key: DataKey) -> Result(String, Nil) {
  element.dataset_get(element, key.key)
}

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

pub fn set_id(elem: Element, ref: ElementRef) -> Element {
  case ref {
    Id(id) -> set_attribute(elem, "id", id)
    Class(_) -> panic as "Unable to set a class ref as id"
    Selector(_) -> panic as "Unable to set a selector ref as id"
  }
}

pub fn set_class(elem: Element, ref: ElementRef) -> Element {
  case ref {
    Id(_) -> panic as "Unable to set an id ref as class"
    Class(class) -> set_attribute(elem, "class", class)
    Selector(_) -> panic as "Unable to set a selector ref as class"
  }
}

pub fn add_class(elem: Element, ref: ElementRef) -> Element {
  case ref {
    Id(_) -> panic as "Unable to set an id ref as class"
    Class(class) -> {
      let existing_class = case element.get_attribute(elem, "class") {
        Ok(class) -> class <> " "
        Error(_) -> ""
      }
      element.set_attribute(elem, "class", existing_class <> class)
      elem
    }
    Selector(_) -> panic as "Unable to set a selector ref as class"
  }
}

pub fn remove_class(elem: Element, ref: ElementRef) -> Element {
  case ref {
    Id(_) -> panic as "Unable to remove an id ref as class"
    Class(class_to_remove) -> {
      case element.get_attribute(elem, "class") {
        Ok(existing) -> {
          let new_class =
            existing
            |> string.split(" ")
            |> list.filter(fn(c) { c != class_to_remove })
            |> string.join(" ")
          element.set_attribute(elem, "class", new_class)
          elem
        }
        Error(_) -> elem
      }
    }
    Selector(_) -> panic as "Unable to remove a selector ref as class"
  }
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

pub fn append_child(to parent: Element, child child: Element) -> Element {
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

pub fn query_element(element: Element, ref: ElementRef) -> Result(Element, Nil) {
  query_element_ffi(element, selector(ref))
}

@external(javascript, "./dromel_ffi.mjs", "element_query_selector")
fn query_element_ffi(element: Element, selector: String) -> Result(Element, Nil)

pub fn query_element_all(
  element: Element,
  ref: ElementRef,
) -> array.Array(Element) {
  query_element_all_ffi(element, selector(ref))
}

@external(javascript, "./dromel_ffi.mjs", "element_query_selector_all")
fn query_element_all_ffi(
  element: Element,
  selector: String,
) -> array.Array(Element)

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

pub fn query_document(ref: ElementRef) -> Result(Element, Nil) {
  document.query_selector(selector(ref))
}

pub fn query_document_all(ref: ElementRef) {
  document.query_selector_all(selector(ref))
}

// ============================================================================
// Element Utilities
// ============================================================================

pub fn cast(target: dynamic.Dynamic) -> Result(Element, decode.DecodeError) {
  element.cast(target)
}
