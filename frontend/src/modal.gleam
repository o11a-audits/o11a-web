import dromel
import elements
import plinth/browser/element
import plinth/browser/event

// ============================================================================
// Generic Modal Configuration
// ============================================================================

pub type ModalConfig(state) {
  ModalConfig(
    // Modal DOM ID reference
    modal_id_ref: dromel.ElementRef,
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
  // Container - the modal content will be rendered into this
  let container =
    dromel.new_div()
    |> dromel.set_style(
      "background: var(--color-body-bg); border: 1px solid var(--color-body-border); border-radius: 4px; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04); overflow: hidden;",
    )

  // Overlay (full screen backdrop, transparent, for click registration outside of the modal)
  let modal =
    dromel.new_div()
    |> dromel.set_id(config.modal_id_ref)
    |> dromel.set_style(
      "position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: transparent; z-index: 1000; display: flex; align-items: center; justify-content: center;",
    )
    |> dromel.append_child(container)
    |> dromel.add_event_listener("keydown", fn(e) {
      case config.get_state() {
        Ok(state) -> config.on_keydown(e, state)
        Error(_) -> Nil
      }
    })
    |> dromel.add_event_listener("click", fn(e) {
      case event.target(e) {
        target -> {
          case dromel.cast(target) {
            Ok(elem) -> {
              // Check if clicked element is the modal overlay itself
              case dromel.matches_ref(elem, config.modal_id_ref) {
                True -> close_modal(config)
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
  case dromel.query_selector(elements.contracts_modal_id) {
    Ok(_existing_modal) -> {
      // Modal already open, just call the callback
      on_opened()
    }
    Error(_) -> {
      // Modal not open, create it
      config.init_state()

      let modal = create_modal_dom(config)

      // Append to #app div
      case dromel.query_selector(elements.app_id) {
        Ok(app_div) -> {
          let _ = app_div |> dromel.append_child(modal)

          // Render content into the container
          case dromel.query_selector(elements.contracts_modal_container) {
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
  case dromel.query_selector(elements.contracts_modal_id) {
    Ok(modal) -> {
      let _ = modal |> dromel.remove()
      config.clear_state()
      clear_input_context()
      Nil
    }
    Error(_) -> Nil
  }
}
