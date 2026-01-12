import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/timestamp
import snag
import tempo/instant

// =============================================================================
// Types
// =============================================================================

pub type Parent {
  Parent(id: String, line_number: Int)
}

pub type HistoryEntry {
  HistoryEntry(
    id: String,
    topic_id: String,
    name: String,
    parent: Option(Parent),
    children: List(String),
  )
}

// =============================================================================
// FFI - Memory Layer
// =============================================================================

@external(javascript, "./mem_ffi.mjs", "get_navigation_entry")
fn get_navigation_entry(id: String) -> Result(HistoryEntry, Nil)

@external(javascript, "./mem_ffi.mjs", "set_navigation_entry")
fn set_navigation_entry(id: String, entry: HistoryEntry) -> Nil

// =============================================================================
// Public API - High-level operations with persistence
// =============================================================================

/// Create a new root entry for a pane's history
pub fn create_root(topic_id: String, name: String) -> String {
  let entry_id = generate_id()
  let entry =
    HistoryEntry(
      id: entry_id,
      topic_id: topic_id,
      name: name,
      parent: None,
      children: [],
    )
  set_navigation_entry(entry.id, entry)
  entry_id
}

/// Navigate to a new location from the current entry
/// Creates a new child entry with the parent info set
pub fn navigate_to(
  current_entry_id: String,
  current_line_number: Int,
  new_topic_id: String,
  new_name: String,
) -> Result(String, snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(current_entry) -> {
      // Create new child entry with parent info
      let new_entry_id = generate_id()
      let new_entry =
        HistoryEntry(
          id: new_entry_id,
          topic_id: new_topic_id,
          name: new_name,
          parent: Some(Parent(
            id: current_entry_id,
            line_number: current_line_number,
          )),
          children: [],
        )

      // Update current entry to add child
      let updated_current_entry =
        HistoryEntry(..current_entry, children: [
          new_entry_id,
          ..current_entry.children
        ])

      // Write both entries
      set_navigation_entry(updated_current_entry.id, updated_current_entry)
      set_navigation_entry(new_entry.id, new_entry)

      Ok(new_entry_id)
    }
  }
}

/// Go back to parent entry (if exists)
/// Returns the parent entry ID and the line number to navigate to
pub fn go_back(current_entry_id: String) -> Result(#(String, Int), snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case entry.parent {
        None -> snag.error("Already at root, cannot go back")
        Some(Parent(id: parent_id, line_number: line_num)) ->
          Ok(#(parent_id, line_num))
      }
    }
  }
}

/// Go forward to the most recent child (first in list)
pub fn go_forward(current_entry_id: String) -> Result(String, snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case entry.children {
        [] -> snag.error("No forward history available")
        [first_child, ..] -> Ok(first_child)
      }
    }
  }
}

/// Go forward to a specific child by index
pub fn go_forward_to_branch(
  current_entry_id: String,
  child_index: Int,
) -> Result(String, snag.Snag) {
  case get_navigation_entry(current_entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> current_entry_id)
    Ok(entry) -> {
      case get_child_at_index(entry.children, child_index) {
        Error(Nil) -> snag.error("Child index out of bounds")
        Ok(child_id) -> Ok(child_id)
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
        |> list.index_map(fn(child_id, index) {
          case get_navigation_entry(child_id) {
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
pub fn get_parent_chain(entry_id: String) -> Result(List(HistoryEntry), snag.Snag) {
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
    Some(Parent(id: parent_id, line_number: _)) -> {
      case get_navigation_entry(parent_id) {
        Ok(parent_entry) -> build_parent_chain(parent_entry, new_acc)
        Error(_) -> new_acc
      }
    }
  }
}

/// Get just the entry data without navigating
pub fn get_entry(entry_id: String) -> Result(HistoryEntry, snag.Snag) {
  case get_navigation_entry(entry_id) {
    Error(Nil) -> snag.error("Failed to read history entry: " <> entry_id)
    Ok(entry) -> Ok(entry)
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
    Some(Parent(id: parent_id, line_number: _)) -> {
      case get_navigation_entry(parent_id) {
        Error(Nil) -> Nil
        Ok(parent_entry) -> {
          // Remove all children except the current entry from parent
          let siblings_to_remove =
            parent_entry.children
            |> list.filter(fn(child_id) { child_id != entry.id })

          // Delete all sibling branches recursively
          list.each(siblings_to_remove, delete_branch)

          // Update parent to only have current entry as child
          let pruned_parent = HistoryEntry(..parent_entry, children: [entry.id])
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
      list.each(entry.children, delete_branch)
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
fn get_child_at_index(children: List(String), index: Int) -> Result(String, Nil) {
  case index, children {
    _, [] -> Error(Nil)
    0, [first, ..] -> Ok(first)
    n, [_, ..rest] if n > 0 -> get_child_at_index(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

fn generate_id() -> String {
  let now = instant.now()

  instant.as_timestamp(now) |> timestamp.to_unix_seconds |> float.to_string
  <> "-"
  <> instant.to_unique_int(now) |> int.to_string
}
