import gleam/io
import snag

const source_error_style = "color: var(--color-body-text); padding: 1rem;"

/// Render a source fetch error as HTML
pub fn render_source_error(error: snag.Snag) -> String {
  "<div style='"
  <> source_error_style
  <> "'>"
  <> error
  |> snag.layer("Unable to fetch source")
  |> snag.pretty_print
  <> "</div>"
}

pub fn print_error(error: snag.Snag) {
  error
  |> snag.line_print
  |> io.println_error
}
