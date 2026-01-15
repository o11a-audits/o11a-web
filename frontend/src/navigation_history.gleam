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

pub type Relative {
  Relative(id: String, child_topic_number: Int)
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

@external(javascript, "./mem_ffi.mjs", "get_navigation_entry")
pub fn get_navigation_entry(id: String) -> Result(HistoryEntry, Nil)

@external(javascript, "./mem_ffi.mjs", "set_navigation_entry")
pub fn set_navigation_entry(id: String, entry: HistoryEntry) -> Nil

// =============================================================================
// Public API - High-level operations with persistence
// =============================================================================

/// Create a new root entry for a pane's history
pub fn create_root(topic: audit_data.Topic) {
  let entry_id = generate_id()
  let entry =
    HistoryEntry(id: entry_id, topic_id: topic.id, parent: None, children: [])
  set_navigation_entry(entry.id, entry)
  entry
}

/// Navigate to a new location from the current entry
/// Creates a new child entry with the parent info set
pub fn go_to_new_entry(
  current_entry_id: String,
  current_child_topic_number: Int,
  new_topic: audit_data.Topic,
) -> Result(HistoryEntry, snag.Snag) {
  case get_navigation_entry(current_entry_id) {
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
            child_topic_number: current_child_topic_number,
          )),
          children: [],
        )

      // Update current entry to add child
      let updated_current_entry =
        HistoryEntry(..current_entry, children: [
          Relative(id: new_entry_id, child_topic_number: 0),
          ..current_entry.children
        ])

      // Write both entries
      set_navigation_entry(updated_current_entry.id, updated_current_entry)
      set_navigation_entry(new_entry.id, new_entry)

      Ok(new_entry)
    }
  }
}

/// Go back to parent entry (if exists)
/// Returns the parent entry and the child topic number to navigate to
pub fn go_back(
  current_entry_id: String,
) -> Result(#(HistoryEntry, Int), snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case entry.parent {
        None -> snag.error("Already at root, cannot go back")
        Some(Relative(id: parent_id, child_topic_number: child_num)) ->
          case get_navigation_entry(parent_id) {
            Error(Nil) -> snag.error("Failed to read parent history entry")
            Ok(parent_entry) -> {
              Ok(#(parent_entry, child_num))
            }
          }
      }
    }
  }
}

/// Go forward to the most recent child (first in list)
pub fn go_forward(current_entry_id: String) -> Result(#(String, Int), snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case entry.children {
        [] -> snag.error("No forward history available")
        [first_child, ..] -> {
          Ok(#(first_child.id, first_child.child_topic_number))
        }
      }
    }
  }
}

/// Go forward to a specific child by index
pub fn go_forward_to_branch(
  current_entry_id: String,
  child_index: Int,
) -> Result(#(String, Int), snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) ->
      snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case get_child_at_index(entry.children, child_index) {
        Error(Nil) -> snag.error("Child index out of bounds")
        Ok(child) -> Ok(#(child.id, child.child_topic_number))
      }
    }
  }
}

/// Get all forward branches from an entry (for UI display)
pub fn get_forward_branches(
  entry_id: String,
) -> Result(List(#(Int, HistoryEntry)), snag.Snag) {
  case get_navigation_entry(entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> entry_id)
    Ok(entry) -> {
      let branches =
        entry.children
        |> list.index_map(fn(child, index) {
          case get_navigation_entry(child.id) {
            Ok(child_entry) -> Ok(#(index, child_entry))
            Error(_) -> Error(Nil)
          }
        })
        |> list.filter_map(fn(x) { x })

      Ok(branches)
    }
  }
}

/// Check if can navigate back from an entry
pub fn can_go_back(entry_id: String) -> Bool {
  case get_navigation_entry(entry_id) {
    Error(_) -> False
    Ok(entry) ->
      case entry.parent {
        None -> False
        Some(_) -> True
      }
  }
}

/// Check if can navigate forward from an entry
pub fn can_go_forward(entry_id: String) -> Bool {
  case get_navigation_entry(entry_id) {
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
pub fn get_parent_chain(
  entry_id: String,
) -> Result(List(HistoryEntry), snag.Snag) {
  case get_navigation_entry(entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> entry_id)
    Ok(entry) -> Ok(build_parent_chain(entry, []))
  }
}

fn build_parent_chain(
  entry: HistoryEntry,
  acc: List(HistoryEntry),
) -> List(HistoryEntry) {
  let new_acc = [entry, ..acc]
  case entry.parent {
    None -> new_acc
    Some(Relative(id: parent_id, ..)) -> {
      case get_navigation_entry(parent_id) {
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
  case get_navigation_entry(entry_id) {
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
      case get_navigation_entry(parent_id) {
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
          set_navigation_entry(pruned_parent.id, pruned_parent)

          // Continue pruning up the tree
          prune_from_entry(parent_entry)
        }
      }
    }
  }
}

fn delete_branch(entry_id: String) -> Nil {
  case get_navigation_entry(entry_id) {
    Error(Nil) -> Nil
    Ok(entry) -> {
      // Recursively delete all children first
      list.each(entry.children, fn(child) { delete_branch(child.id) })
      // Note: In a real implementation, you'd need a delete_navigation_entry FFI function
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
