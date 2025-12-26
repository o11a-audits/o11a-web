import audit_data
import dromel
import plinth/browser/element
import plinth/browser/event

// ============================================================================
// Modal Type
// ============================================================================

pub type Modal {
  Modal(overlay: element.Element, container: element.Element)
}

// ============================================================================
// Generic Modal IDs (shared by all modals - only one can be open at a time)
// ============================================================================

const modal_overlay_ref = dromel.Id(id: "modal-overlay")

const modal_container_ref = dromel.Id(id: "modal-container")

// ============================================================================
// Focus Context Management
// ============================================================================

@external(javascript, "../mem_ffi.mjs", "set_input_context")
pub fn set_input_context() -> Nil

@external(javascript, "../mem_ffi.mjs", "clear_input_context")
pub fn clear_input_context() -> Nil

@external(javascript, "../mem_ffi.mjs", "is_in_input_context")
pub fn is_in_input_context() -> Bool

// ============================================================================
// Modal Lifecycle
// ============================================================================

pub fn open_modal(render: fn(element.Element) -> Nil) -> Modal {
  let container =
    dromel.new_div()
    |> dromel.set_id(modal_container_ref)
    |> dromel.set_style(
      "background: var(--color-body-bg); border: 1px solid var(--color-body-border); border-radius: 4px; box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04); overflow: hidden;",
    )

  let overlay =
    dromel.new_div()
    |> dromel.set_id(modal_overlay_ref)
    |> dromel.set_style(
      "position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: transparent; z-index: 1000; display: flex; align-items: center; justify-content: center;",
    )
    |> dromel.append_child(container)

  let _ =
    overlay
    |> dromel.add_event_listener("click", fn(e) {
      case dromel.cast(event.target(e)) {
        Ok(elem) -> {
          case dromel.matches_ref(elem, modal_overlay_ref) {
            True -> close_modal(overlay)
            _ -> Nil
          }
        }
        Error(_) -> Nil
      }
    })

  let _ = audit_data.app_element() |> dromel.append_child(overlay)

  render(container)

  Modal(overlay: overlay, container: container)
}

pub fn close_modal(overlay: element.Element) -> Nil {
  let _ = dromel.remove(overlay)
  clear_input_context()
}
