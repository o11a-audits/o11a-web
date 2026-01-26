import filepath
import gleam/erlang/process
import mist
import simplifile
import wisp
import wisp/wisp_mist

pub type Context {
  Context(static_directory: String)
}

pub fn main() {
  wisp.configure_logger()
  let secret_key_base = wisp.random_string(64)

  let static_directory = static_directory()

  // A context is constructed holding the static directory path.
  let ctx = Context(static_directory:)

  // The handle_request function is partially applied with the context to make
  // the request handler function that only takes a request.
  let handler = handle_request(_, ctx)

  let assert Ok(_) =
    wisp_mist.handler(handler, secret_key_base)
    |> mist.new
    |> mist.bind("0.0.0.0")
    |> mist.port(8001)
    |> mist.start

  process.sleep_forever()
}

pub fn static_directory() -> String {
  // The priv directory is where we store non-Gleam and non-Erlang files,
  // including static assets to be served.
  // This function returns an absolute path and works both in development and in
  // production after compilation.
  let assert Ok(priv_directory) = wisp.priv_directory("server")
  priv_directory <> "/static"
}

pub fn handle_request(req: wisp.Request, ctx: Context) -> wisp.Response {
  use _req <- middleware(req, ctx)

  let assert Ok(index_html) =
    simplifile.read(filepath.join(ctx.static_directory, "index.html"))

  wisp.html_response(index_html, 200)
}

pub fn middleware(
  req: wisp.Request,
  ctx: Context,
  handle_request: fn(wisp.Request) -> wisp.Response,
) -> wisp.Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use req <- wisp.csrf_known_header_protection(req)
  use <- wisp.serve_static(req, under: "/static", from: ctx.static_directory)

  handle_request(req)
}
