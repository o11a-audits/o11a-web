import esgleam

pub fn main() {
  esgleam.new("../server/priv/static")
  |> esgleam.entry("o11a_web.gleam")
  |> esgleam.bundle
}
