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

pub type HistoryNode {
  HistoryNode(
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

@external(javascript, "./mem_ffi.mjs", "get_navigation_node")
fn get_navigation_node(id: String) -> Result(HistoryNode, Nil)

@external(javascript, "./mem_ffi.mjs", "set_navigation_node")
fn set_navigation_node(id: String, node: HistoryNode) -> Nil

// =============================================================================
// Public API - High-level operations with persistence
// =============================================================================

/// Create a new root node for a pane's history
pub fn create_root(topic_id: String, name: String) -> String {
  let node_id = generate_id()
  let node =
    HistoryNode(
      id: node_id,
      topic_id: topic_id,
      name: name,
      parent: None,
      children: [],
    )
  set_navigation_node(node.id, node)
  node_id
}

/// Navigate to a new location from the current node
/// Creates a new child node with the parent info set
pub fn navigate_to(
  current_node_id: String,
  current_line_number: Int,
  new_topic_id: String,
  new_name: String,
) -> Result(String, snag.Snag) {
  case get_navigation_node(current_node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> current_node_id)
    Ok(current_node) -> {
      // Create new child node with parent info
      let new_node_id = generate_id()
      let new_node =
        HistoryNode(
          id: new_node_id,
          topic_id: new_topic_id,
          name: new_name,
          parent: Some(Parent(
            id: current_node_id,
            line_number: current_line_number,
          )),
          children: [],
        )

      // Update current node to add child
      let updated_current_node =
        HistoryNode(..current_node, children: [
          new_node_id,
          ..current_node.children
        ])

      // Write both nodes
      set_navigation_node(updated_current_node.id, updated_current_node)
      set_navigation_node(new_node.id, new_node)

      Ok(new_node_id)
    }
  }
}

/// Go back to parent node (if exists)
/// Returns the parent node ID and the line number to navigate to
pub fn go_back(current_node_id: String) -> Result(#(String, Int), snag.Snag) {
  case get_navigation_node(current_node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> current_node_id)
    Ok(node) -> {
      case node.parent {
        None -> snag.error("Already at root, cannot go back")
        Some(Parent(id: parent_id, line_number: line_num)) ->
          Ok(#(parent_id, line_num))
      }
    }
  }
}

/// Go forward to the most recent child (first in list)
pub fn go_forward(current_node_id: String) -> Result(String, snag.Snag) {
  case get_navigation_node(current_node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> current_node_id)
    Ok(node) -> {
      case node.children {
        [] -> snag.error("No forward history available")
        [first_child, ..] -> Ok(first_child)
      }
    }
  }
}

/// Go forward to a specific child by index
pub fn go_forward_to_branch(
  current_node_id: String,
  child_index: Int,
) -> Result(String, snag.Snag) {
  case get_navigation_node(current_node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> current_node_id)
    Ok(node) -> {
      case get_child_at_index(node.children, child_index) {
        Error(Nil) -> snag.error("Child index out of bounds")
        Ok(child_id) -> Ok(child_id)
      }
    }
  }
}

/// Get all forward branches from a node (for UI display)
pub fn get_forward_branches(
  node_id: String,
) -> Result(List(#(Int, HistoryNode)), snag.Snag) {
  case get_navigation_node(node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> node_id)
    Ok(node) -> {
      let branches =
        node.children
        |> list.index_map(fn(child_id, index) {
          case get_navigation_node(child_id) {
            Ok(child_node) -> Ok(#(index, child_node))
            Error(_) -> Error(Nil)
          }
        })
        |> list.filter_map(fn(x) { x })

      Ok(branches)
    }
  }
}

/// Check if can navigate back from a node
pub fn can_go_back(node_id: String) -> Bool {
  case get_navigation_node(node_id) {
    Error(_) -> False
    Ok(node) ->
      case node.parent {
        None -> False
        Some(_) -> True
      }
  }
}

/// Check if can navigate forward from a node
pub fn can_go_forward(node_id: String) -> Bool {
  case get_navigation_node(node_id) {
    Error(_) -> False
    Ok(node) ->
      case node.children {
        [] -> False
        _ -> True
      }
  }
}

/// Get the parent chain from a node up to the root
/// Returns a list starting from the given node and going up to the root
pub fn get_parent_chain(node_id: String) -> Result(List(HistoryNode), snag.Snag) {
  case get_navigation_node(node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> node_id)
    Ok(node) -> Ok(build_parent_chain(node, []))
  }
}

fn build_parent_chain(
  node: HistoryNode,
  acc: List(HistoryNode),
) -> List(HistoryNode) {
  let new_acc = [node, ..acc]
  case node.parent {
    None -> new_acc
    Some(Parent(id: parent_id, line_number: _)) -> {
      case get_navigation_node(parent_id) {
        Ok(parent_node) -> build_parent_chain(parent_node, new_acc)
        Error(_) -> new_acc
      }
    }
  }
}

/// Get just the node data without navigating
pub fn get_node(node_id: String) -> Result(HistoryNode, snag.Snag) {
  case get_navigation_node(node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> node_id)
    Ok(node) -> Ok(node)
  }
}

/// Prune history by removing all sibling branches
/// Starting from the given node, walks up to the root and removes all children
/// from each parent except the one in the current chain
pub fn prune_history(node_id: String) -> Result(Nil, snag.Snag) {
  case get_navigation_node(node_id) {
    Error(Nil) -> snag.error("Failed to read history node: " <> node_id)
    Ok(node) -> {
      prune_from_node(node)
      Ok(Nil)
    }
  }
}

fn prune_from_node(node: HistoryNode) -> Nil {
  case node.parent {
    None -> Nil
    Some(Parent(id: parent_id, line_number: _)) -> {
      case get_navigation_node(parent_id) {
        Error(Nil) -> Nil
        Ok(parent_node) -> {
          // Remove all children except the current node from parent
          let siblings_to_remove =
            parent_node.children
            |> list.filter(fn(child_id) { child_id != node.id })

          // Delete all sibling branches recursively
          list.each(siblings_to_remove, delete_branch)

          // Update parent to only have current node as child
          let pruned_parent = HistoryNode(..parent_node, children: [node.id])
          set_navigation_node(pruned_parent.id, pruned_parent)

          // Continue pruning up the tree
          prune_from_node(parent_node)
        }
      }
    }
  }
}

fn delete_branch(node_id: String) -> Nil {
  case get_navigation_node(node_id) {
    Error(Nil) -> Nil
    Ok(node) -> {
      // Recursively delete all children first
      list.each(node.children, delete_branch)
      // Note: In a real implementation, you'd need a delete_navigation_node FFI function
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
