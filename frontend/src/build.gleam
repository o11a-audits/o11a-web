//// This module can be run to build the frontend assets to be served
//// by the server in the ../server directory

import esgleam

pub fn main() {
  esgleam.new("../server/priv/static")
  |> esgleam.entry("o11a_web.gleam")
  |> esgleam.bundle
}
