import audit_data
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import snag
import tempo/datetime
import tempo/instant

// =============================================================================
// Types
// =============================================================================

/// Which panel has focus in the topic view
pub type ActivePanel {
  ConversationPanel
  TopicPanel
  ReferencesPanel
}

pub fn active_panel_to_string(active_panel: ActivePanel) -> String {
  case active_panel {
    ConversationPanel -> "conversation"
    TopicPanel -> "topic"
    ReferencesPanel -> "references"
  }
}

pub fn active_panel_from_string(string: String) {
  case string {
    "conversation" -> Ok(ConversationPanel)
    "topic" -> Ok(TopicPanel)
    "references" -> Ok(ReferencesPanel)
    _ -> snag.error("Unknown panel: " <> string)
  }
}

/// Focus state capturing the user's position in all four panels.
/// Stores data-node-topic identifiers instead of indices so that
/// focus is resilient to token insertions/removals (e.g. new comments).
pub type FocusState {
  FocusState(
    conversation_node_topic: String,
    topic_node_topic: String,
    references_node_topic: String,
    active_panel: ActivePanel,
  )
}

/// Default focus state for new entries
pub fn default_focus_state() -> FocusState {
  FocusState(
    conversation_node_topic: "",
    topic_node_topic: "",
    references_node_topic: "",
    active_panel: TopicPanel,
  )
}

pub type Relative {
  Relative(id: String, focus_state: FocusState)
}

pub type HistoryEntry {
  HistoryEntry(
    id: String,
    topic_id: String,
    parent: Option(Relative),
    children: List(Relative),
  )
}

// =============================================================================
// FFI - Memory Layer
// =============================================================================

@external(javascript, "./mem_ffi.mjs", "get_history_entry")
pub fn get_history_entry(id: String) -> Result(HistoryEntry, Nil)

@external(javascript, "./mem_ffi.mjs", "set_history_entry")
pub fn set_history_entry(id: String, entry: HistoryEntry) -> Nil

// =============================================================================
// Public API - High-level operations with persistence
// =============================================================================

/// Create a new root entry for a pane's history
pub fn create_root(topic: audit_data.Topic) {
  let entry_id = generate_id()
  let entry =
    HistoryEntry(id: entry_id, topic_id: topic.id, parent: None, children: [])
  set_history_entry(entry.id, entry)
  entry
}

/// Create a new child history entry from the current entry
/// Sets up parent-child relationship between entries
pub fn go_to_new_entry(
  current_entry_id: String,
  current_focus_state: FocusState,
  new_topic: audit_data.Topic,
) -> Result(HistoryEntry, snag.Snag) {
  case get_history_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(current_entry) -> {
      // Create new child entry with parent info
      let new_entry_id = generate_id()
      let new_entry =
        HistoryEntry(
          id: new_entry_id,
          topic_id: new_topic.id,
          parent: Some(Relative(
            id: current_entry_id,
            focus_state: current_focus_state,
          )),
          children: [],
        )

      // Update current entry to add child
      let updated_current_entry =
        HistoryEntry(..current_entry, children: [
          Relative(id: new_entry_id, focus_state: default_focus_state()),
          ..current_entry.children
        ])

      // Write both entries
      set_history_entry(updated_current_entry.id, updated_current_entry)
      set_history_entry(new_entry.id, new_entry)

      Ok(new_entry)
    }
  }
}

/// Go back to parent entry (if exists)
/// Returns the parent entry and the focus state to restore
pub fn go_back(
  current_entry_id: String,
) -> Result(#(HistoryEntry, FocusState), snag.Snag) {
  case get_history_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) ->
      case entry.parent {
        None -> snag.error("Already at root, cannot go back")
        Some(Relative(id: parent_id, focus_state:)) ->
          case get_history_entry(parent_id) {
            Error(Nil) -> snag.error("Failed to read parent history entry")
            Ok(parent_entry) -> {
              Ok(#(parent_entry, focus_state))
            }
          }
      }
  }
}

/// Go forward to the most recent child (first in list)
/// Returns the child entry and the focus state to restore
pub fn go_forward(
  current_entry_id: String,
) -> Result(#(HistoryEntry, FocusState), snag.Snag) {
  case get_history_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) ->
      case entry.children {
        [] -> snag.error("No forward history available")
        [first_child, ..] ->
          case get_history_entry(first_child.id) {
            Error(Nil) -> snag.error("Failed to read child history entry")
            Ok(child_entry) -> {
              Ok(#(child_entry, first_child.focus_state))
            }
          }
      }
  }
}

/// Go forward to a specific child by index
/// Returns the child entry id and the focus state to restore
pub fn go_forward_to_branch(
  current_entry_id: String,
  child_index: Int,
) -> Result(#(String, FocusState), snag.Snag) {
  case get_history_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case get_child_at_index(entry.children, child_index) {
        Error(Nil) -> snag.error("Child index out of bounds")
        Ok(child) -> Ok(#(child.id, child.focus_state))
      }
    }
  }
}

/// Get all forward branches from an entry (for UI display)
pub fn get_forward_branches(entry: HistoryEntry) -> List(#(Int, HistoryEntry)) {
  entry.children
  |> list.index_map(fn(child, index) {
    case get_history_entry(child.id) {
      Ok(child_entry) -> Ok(#(index, child_entry))
      Error(_) -> Error(Nil)
    }
  })
  |> list.filter_map(fn(x) { x })
}

/// Check if a parent entry exists
pub fn can_go_back(entry_id: String) -> Bool {
  case get_history_entry(entry_id) {
    Error(_) -> False
    Ok(entry) ->
      case entry.parent {
        None -> False
        Some(_) -> True
      }
  }
}

/// Check if child entries exist
pub fn can_go_forward(entry_id: String) -> Bool {
  case get_history_entry(entry_id) {
    Error(_) -> False
    Ok(entry) ->
      case entry.children {
        [] -> False
        _ -> True
      }
  }
}

/// Get the parent chain from an entry up to the root
/// Returns a list starting from the given entry and going up to the root
pub fn get_parent_chain(entry: HistoryEntry) -> List(HistoryEntry) {
  build_parent_chain(entry, [])
}

fn build_parent_chain(
  entry: HistoryEntry,
  acc: List(HistoryEntry),
) -> List(HistoryEntry) {
  let new_acc = [entry, ..acc]
  case entry.parent {
    None -> new_acc
    Some(Relative(id: parent_id, ..)) -> {
      case get_history_entry(parent_id) {
        Ok(parent_entry) -> build_parent_chain(parent_entry, new_acc)
        Error(_) -> new_acc
      }
    }
  }
}

/// Prune history by removing all sibling branches
/// Starting from the given entry, walks up to the root and removes all children
/// from each parent except the one in the current chain
pub fn prune_history(entry_id: String) -> Result(Nil, snag.Snag) {
  case get_history_entry(entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> entry_id)
    Ok(entry) -> {
      prune_from_entry(entry)
      Ok(Nil)
    }
  }
}

fn prune_from_entry(entry: HistoryEntry) -> Nil {
  case entry.parent {
    None -> Nil
    Some(Relative(id: parent_id, ..)) -> {
      case get_history_entry(parent_id) {
        Error(Nil) -> Nil
        Ok(parent_entry) -> {
          // Remove all children except the current entry from parent
          let siblings_to_remove =
            parent_entry.children
            |> list.filter(fn(child) { child.id != entry.id })

          // Delete all sibling branches recursively
          list.each(siblings_to_remove, fn(child) { delete_branch(child.id) })

          // Update parent to only have current entry as child
          let siblings_to_keep =
            parent_entry.children
            |> list.filter(fn(child) { child.id == entry.id })
          let pruned_parent =
            HistoryEntry(..parent_entry, children: siblings_to_keep)
          set_history_entry(pruned_parent.id, pruned_parent)

          // Continue pruning up the tree
          prune_from_entry(parent_entry)
        }
      }
    }
  }
}

fn delete_branch(entry_id: String) -> Nil {
  case get_history_entry(entry_id) {
    Error(Nil) -> Nil
    Ok(entry) -> {
      // Recursively delete all children first
      list.each(entry.children, fn(child) { delete_branch(child.id) })
      // Note: In a real implementation, you'd need a delete_history_entry FFI function
      // For now, this structure shows the logic - the actual deletion would happen here
      Nil
    }
  }
}

// =============================================================================
// Helper functions
// =============================================================================

/// Helper to get element at index in a list
fn get_child_at_index(children: List(a), index: Int) -> Result(a, Nil) {
  case index, children {
    _, [] -> Error(Nil)
    0, [first, ..] -> Ok(first)
    n, [_, ..rest] if n > 0 -> get_child_at_index(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

fn generate_id() -> String {
  let now = instant.now()

  instant.as_utc_datetime(now) |> datetime.to_unix_milli |> int.to_string
  <> "-"
  <> instant.to_unique_int(now) |> int.to_string
}
