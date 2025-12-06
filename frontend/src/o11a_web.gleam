import gleam/io
import plinth/browser/window

pub fn main(name) -> Nil {
  io.println(
    "Hello "
    <> name
    <> " from o11a_web at "
    <> window.pathname()
    <> " location!",
  )
}
