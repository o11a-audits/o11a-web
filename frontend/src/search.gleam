import gleam/list
import gleam/string

// ============================================================================
// Generic Search/Filter Utilities
// ============================================================================

/// Filter a list of items by a search query using a custom accessor function
pub fn filter(
  items: List(a),
  query: String,
  get_searchable_text: fn(a) -> String,
) -> List(a) {
  case string.trim(query) {
    "" -> items
    q -> {
      let lower_query = string.lowercase(q)
      list.filter(items, fn(item) {
        get_searchable_text(item)
        |> string.lowercase
        |> string.contains(lower_query)
      })
    }
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
