import plinth/browser/document
import plinth/browser/element
import plinth/browser/event

// ============================================================================
// Generic Modal Configuration
// ============================================================================

pub type ModalConfig(state) {
  ModalConfig(
    // Modal DOM ID
    modal_id: String,
    // Render the modal content (receives the container element)
    render_content: fn(element.Element, state) -> Nil,
    // Handle keyboard events
    on_keydown: fn(event.Event(event.UIEvent(event.KeyboardEvent)), state) ->
      Nil,
    // Initialize modal state
    init_state: fn() -> Nil,
    // Get current modal state
    get_state: fn() -> Result(state, Nil),
    // Clear modal state
    clear_state: fn() -> Nil,
  )
}

// ============================================================================
// Focus Context Management
// ============================================================================

@external(javascript, "./mem_ffi.mjs", "set_input_context")
pub fn set_input_context() -> Nil

@external(javascript, "./mem_ffi.mjs", "clear_input_context")
pub fn clear_input_context() -> Nil

@external(javascript, "./mem_ffi.mjs", "is_in_input_context")
pub fn is_in_input_context() -> Bool

// ============================================================================
// Generic Modal DOM Creation
// ============================================================================

pub fn create_modal_dom(config: ModalConfig(state)) -> element.Element {
  // Overlay (full screen backdrop, transparent)
  let modal = document.create_element("div")
  element.set_attribute(modal, "id", config.modal_id)
  element.set_attribute(
    modal,
    "style",
    "position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: transparent; z-index: 1000; display: flex; align-items: center; justify-content: center;",
  )

  // Container - the modal content will be rendered into this
  let container = document.create_element("div")
  element.set_attribute(
    container,
    "style",
    "background: var(--color-body-bg); border: 1px solid var(--color-body-border); border-radius: 4px; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04);",
  )

  element.append_child(modal, container)

  // Attach keydown listener
  let _keydown_cleanup =
    element.add_event_listener(modal, "keydown", fn(e) {
      case config.get_state() {
        Ok(state) -> config.on_keydown(e, state)
        Error(_) -> Nil
      }
    })

  // Click on overlay to close
  let _click_cleanup =
    element.add_event_listener(modal, "click", fn(e) {
      case event.target(e) {
        target -> {
          case element.cast(target) {
            Ok(elem) -> {
              case element.get_attribute(elem, "id") {
                Ok(id) if id == config.modal_id -> close_modal(config)
                _ -> Nil
              }
            }
            Error(_) -> Nil
          }
        }
      }
    })

  modal
}

// ============================================================================
// Modal Lifecycle
// ============================================================================

pub fn open_modal(config: ModalConfig(state), on_opened: fn() -> Nil) -> Nil {
  // Check if modal is already open
  case document.query_selector("#" <> config.modal_id) {
    Ok(_existing_modal) -> {
      // Modal already open, just call the callback
      on_opened()
    }
    Error(_) -> {
      // Modal not open, create it
      config.init_state()

      let modal = create_modal_dom(config)

      // Append to #app div
      case document.query_selector("#app") {
        Ok(app_div) -> {
          element.append_child(app_div, modal)

          // Render content into the container
          case document.query_selector("#" <> config.modal_id <> " > div") {
            Ok(container) -> {
              case config.get_state() {
                Ok(state) -> config.render_content(container, state)
                Error(_) -> Nil
              }
            }
            Error(_) -> Nil
          }

          // Call the opened callback
          on_opened()
        }
        Error(_) -> Nil
      }
    }
  }
}

pub fn close_modal(config: ModalConfig(state)) -> Nil {
  case document.query_selector("#" <> config.modal_id) {
    Ok(modal) -> {
      element.remove(modal)
      config.clear_state()
      clear_input_context()
      Nil
    }
    Error(_) -> Nil
  }
}
