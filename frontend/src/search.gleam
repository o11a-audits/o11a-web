import gleam/list
import gleam/order
import gleam/string

// ============================================================================
// Generic Search/Filter Utilities
// ============================================================================

/// Filter and rank a list of items by a search query using a custom accessor function
/// Items are sorted by match quality (best matches first)
pub fn filter(
  items: List(a),
  query: String,
  get_searchable_text: fn(a) -> String,
) -> List(a) {
  case string.trim(query) {
    "" -> items
    q -> {
      let lower_query = string.lowercase(q)

      // Filter and rank items
      items
      |> list.filter_map(fn(item) {
        let text = get_searchable_text(item)
        let rank = rank_match(text, lower_query)

        case rank >= 0 {
          True -> Ok(#(item, rank))
          False -> Error(Nil)
        }
      })
      // Sort by rank (highest first)
      |> list.sort(fn(a, b) {
        let #(_, rank_a) = a
        let #(_, rank_b) = b
        case rank_a > rank_b {
          True -> order.Lt
          False ->
            case rank_a < rank_b {
              True -> order.Gt
              False -> order.Eq
            }
        }
      })
      // Extract just the items
      |> list.map(fn(pair) {
        let #(item, _rank) = pair
        item
      })
    }
  }
}

/// Rank a match based on position and match type
/// Returns -1 for no match, higher scores for better matches
fn rank_match(text: String, query: String) -> Int {
  let lower_text = string.lowercase(text)
  let lower_query = string.lowercase(query)

  case string.split_once(lower_text, lower_query) {
    Ok(#(before, _after)) -> {
      let position = string.length(before)
      let base_score = 1000 - position

      // Calculate bonuses for special match types
      let exact_match_bonus = case lower_text == lower_query {
        True -> 500
        False -> 0
      }

      let starts_with_bonus = case position == 0 {
        True -> 200
        False -> 0
      }

      let word_boundary_bonus = case is_word_boundary(text, position) {
        True -> 100
        False -> 0
      }

      base_score + exact_match_bonus + starts_with_bonus + word_boundary_bonus
    }
    Error(_) -> -1
    // No match
  }
}

/// Check if a position in text is a word boundary
/// Handles PascalCase, camelCase, and snake_case
fn is_word_boundary(text: String, position: Int) -> Bool {
  case position {
    0 -> True
    // Start of string is always a word boundary
    _ -> {
      // Check character before the position
      let char_before = string.slice(text, position - 1, 1)

      // Word boundary if preceded by underscore, space, or dash
      case char_before {
        "_" -> True
        " " -> True
        "-" -> True
        _ -> {
          // Check if current position starts with uppercase (PascalCase/camelCase)
          let char_at_pos = string.slice(text, position, 1)
          is_uppercase(char_at_pos)
        }
      }
    }
  }
}

/// Check if a string is an uppercase letter
fn is_uppercase(s: String) -> Bool {
  case s {
    "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    _ -> False
  }
}

/// Highlight the first occurrence of search query in text (case-insensitive)
/// Returns HTML with the match wrapped in a span with purple color
pub fn highlight_match(text: String, query: String) -> String {
  case string.trim(query) {
    "" -> text
    q -> {
      let lower_text = string.lowercase(text)
      let lower_query = string.lowercase(q)

      case string.split_once(lower_text, lower_query) {
        Ok(#(before_lower, _after_lower)) -> {
          // Calculate positions in original text
          let before_len = string.length(before_lower)
          let query_len = string.length(q)

          // Extract parts from original text preserving case
          let before = string.slice(text, 0, before_len)
          let matched = string.slice(text, before_len, query_len)
          let after =
            string.slice(text, before_len + query_len, string.length(text))

          before
          <> "<span style='color: var(--color-brand-purple);'>"
          <> matched
          <> "</span>"
          <> after
        }
        Error(_) -> text
      }
    }
  }
}
