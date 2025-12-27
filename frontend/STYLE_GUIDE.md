# Frontend Code Style Guide

This document outlines the coding conventions and architectural patterns for the o11a-web frontend codebase.

## Table of Contents

1. [DOM Manipulation & Element References](#dom-manipulation--element-references)
2. [State Management](#state-management)
3. [Function Naming & Organization](#function-naming--organization)
4. [Modal Architecture](#modal-architecture)

---

## DOM Manipulation & Element References

### Prefer Element References Over Query Selectors

**Don't:** Query the DOM repeatedly for the same elements
```gleam
fn render_something() -> Nil {
  case dromel.query_selector(elements.some_element) {
    Ok(elem) -> {
      // do something
    }
    Error(_) -> Nil
  }
}
```

**Do:** Store element references in state or pass them as parameters
```gleam
fn render_something(element: element.Element) -> Nil {
  // Use the element directly
  let _ = element |> dromel.set_inner_html("content")
  Nil
}
```

### Element-First Parameter Order

Functions that render into or manipulate DOM elements should take the element as the **first parameter**, following dromel's conventions.

**Don't:**
```gleam
fn render_list(items: List(a), selected: Int, element: element.Element) -> Nil
fn render_preview(html: String, element: element.Element) -> Nil
```

**Do:**
```gleam
fn render_list(element: element.Element, items: List(a), selected: Int) -> Nil
fn render_preview(element: element.Element, html: String) -> Nil
```

**Rationale:** This matches dromel's API style (e.g., `dromel.append_child(parent, child)`) and makes it clear that the function is operating on that element.

### Generic IDs for Shared Resources

When only one instance of a component can exist at a time (e.g., modals), use **generic IDs** rather than component-specific ones.

**Don't:**
```gleam
const contracts_modal_id = dromel.Id(id: "contracts-modal")
const settings_modal_id = dromel.Id(id: "settings-modal")
```

**Do:**
```gleam
const modal_overlay_ref = dromel.Id(id: "modal-overlay")
const modal_container_ref = dromel.Id(id: "modal-container")
```

**Rationale:** If only one modal can be open at a time, there's no need for unique IDs per modal type.

---

## State Management

### Store DOM References in State

When components need to repeatedly access specific DOM elements, store references in state rather than querying for them.

**Don't:**
```gleam
pub type ModalState {
  ModalState(
    data: List(a),
    selected_index: Int,
  )
}

fn render_list(state: ModalState) -> Nil {
  case dromel.query_selector(elements.list_pane) {
    Ok(pane) -> { /* render */ }
    Error(_) -> Nil
  }
}
```

**Do:**
```gleam
pub type ModalState {
  ModalState(
    data: List(a),
    selected_index: Int,
    list_pane: element.Element,      // Element reference
    preview_pane: element.Element,    // Element reference
  )
}

fn render_list(state: ModalState) -> Nil {
  let _ = state.list_pane |> dromel.set_inner_html("...")
  Nil
}
```

### Initialize State After DOM Creation

Initialize state **after** creating DOM elements so element references are never `Option` types.

**Don't:**
```gleam
fn init_state() -> Nil {
  set_state(State(
    left_pane: None,   // Will be filled in later
    right_pane: None,
  ))
}

fn open() -> Nil {
  init_state()
  let panes = create_dom()
  update_state_with_panes(panes)
}
```

**Do:**
```gleam
fn init_state(left_pane: element.Element, right_pane: element.Element) -> Nil {
  set_state(State(
    left_pane: left_pane,    // Non-optional
    right_pane: right_pane,  // Non-optional
  ))
}

fn open() -> Nil {
  let panes = create_dom()
  init_state(panes.left, panes.right)
}
```

**Rationale:** If elements always exist when state exists, there's no need for `Option` types and no need to handle `None` cases.

### Store UI State in State, Not in the DOM

Don't query the DOM to retrieve application state (e.g., form values, search queries).

**Don't:**
```gleam
fn handle_keydown() -> Nil {
  // Querying DOM for state
  let query = case dromel.query_selector(search_input_class) {
    Ok(input) -> dromel.value(input) |> result.unwrap("")
    Error(_) -> ""
  }
  search(query)
}
```

**Do:**
```gleam
pub type State {
  State(
    search_query: String,  // State holds the query
    ...
  )
}

fn handle_input(query: String, state: State) -> Nil {
  set_state(State(..state, search_query: query))
  search(query)
}

fn handle_keydown(state: State) -> Nil {
  search(state.search_query)  // Read from state
}
```

**Rationale:** State is the single source of truth. The DOM should reflect state, not be the source of it.

---

## Function Naming & Organization

### Use Action Verbs for Lifecycle Functions

Functions that set up or initialize components should use clear action verbs.

**Preferred verbs:**
- `mount_*` - Create DOM structure and initialize state (e.g., `mount_contracts_modal`)
- `render_*` - Update existing DOM with new content (e.g., `render_list`)
- `init_*` - Initialize state/data structures (e.g., `init_state`)
- `open_*` / `close_*` - Lifecycle actions (e.g., `open_modal`, `close_modal`)

**Don't:**
```gleam
fn create_two_pane_layout(container: element.Element) -> #(element.Element, element.Element) {
  // Creates DOM and returns references
  let left = dromel.new_div()
  let right = dromel.new_div()
  #(left, right)
}
```

**Do:**
```gleam
fn mount_contracts_modal(container: element.Element) -> Nil {
  // Creates DOM *and* initializes state
  let left = dromel.new_div()
  let right = dromel.new_div()
  init_state(left, right)
}
```

**Rationale:** "mount" communicates that this function both creates the DOM structure and initializes the component's state, making it ready to use.

---

## Modal Architecture

### Simplified Modal Pattern

Modals should follow this architecture:

1. **Generic modal infrastructure** (`modal.gleam`):
   - Provides `open_modal(render: fn(Element) -> Nil) -> Modal`
   - Returns `Modal(overlay: Element, container: Element)`
   - Handles overlay click-to-close
   - Uses generic IDs (only one modal at a time)

2. **Specific modal implementation** (e.g., `contracts_modal.gleam`):
   - Has a `mount_*` function that creates DOM and initializes state
   - Stores element references in state (non-optional)
   - Render functions take element-first parameters
   - Public `open()` function orchestrates everything

**Example:**

```gleam
// modal.gleam
pub type Modal {
  Modal(overlay: element.Element, container: element.Element)
}

pub fn open_modal(render: fn(element.Element) -> Nil) -> Modal {
  let container = dromel.new_div() |> dromel.set_id(modal_container_ref) |> ...
  let overlay = dromel.new_div() |> dromel.set_id(modal_overlay_ref) |> ...
  let _ = audit_data.app_element() |> dromel.append_child(overlay)
  render(container)
  Modal(overlay: overlay, container: container)
}

pub fn close_modal(overlay: element.Element) -> Nil {
  let _ = dromel.remove(overlay)
  clear_input_context()
}

// contracts_modal.gleam
pub type ContractsModalState {
  ContractsModalState(
    all_contracts: List(ContractMetadata),
    filtered_contracts: List(ContractMetadata),
    selected_index: Int,
    search_query: String,
    left_pane: element.Element,   // Not Option!
    right_pane: element.Element,  // Not Option!
  )
}

fn mount_contracts_modal(container: element.Element) -> Nil {
  // Create DOM structure
  let left_pane = dromel.new_div() |> ...
  let right_pane = dromel.new_div() |> ...
  let _ = container |> dromel.append_child(left_pane)
  let _ = container |> dromel.append_child(right_pane)
  
  // Initialize state with element references
  init_state(left_pane, right_pane)
}

pub fn open() -> Nil {
  let modal_elements = modal.open_modal(mount_contracts_modal)
  
  // Attach event handlers
  let _ = modal_elements.overlay
    |> dromel.add_event_listener("keydown", handle_keydown)
  
  // Load data
  fetch_contracts(on_contracts_loaded)
}
```

### What Goes in State vs. What Doesn't

**Do store in state:**
- ✅ Business data (lists, selected items, etc.)
- ✅ UI state (search queries, selections, current preview ID)
- ✅ Element references for frequently accessed DOM nodes

**Don't store in state:**
- ❌ Functions (render functions, event handlers, etc.)
- ❌ Configuration objects with functions
- ❌ Elements that are only accessed once

**Rationale:** State should represent the current state of the application and UI. Functions and one-time DOM operations don't need to be stored.

---

## Summary

### Key Principles

1. **Minimize query selectors** - Store element references, pass them as parameters
2. **Element-first parameters** - Match dromel's conventions
3. **State is the source of truth** - Don't query DOM for application state
4. **Initialize after creation** - Avoid `Option` types for elements
5. **Clear action verbs** - `mount_*`, `render_*`, `init_*`
6. **Generic over specific** - Use generic IDs when only one instance exists
7. **Simple, direct** - Avoid over-engineering with config objects and function storage
