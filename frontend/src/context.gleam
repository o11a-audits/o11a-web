import gleam/list

pub type Context {
  Default
  ContractsModal
  Input
}

pub fn init_context() {
  set_context([Default])
}

pub fn get_current_context() -> Context {
  case get_context_ffi() {
    [first, ..] -> first
    _ -> Default
  }
}

@external(javascript, "./mem_ffi.mjs", "get_context")
fn get_context_ffi() -> List(Context)

@external(javascript, "./mem_ffi.mjs", "set_context")
fn set_context(context: List(Context)) -> Nil

pub fn add_context(new_context: Context) {
  [new_context, ..get_context_ffi()]
  |> set_context
}

pub fn remove_context(existing_context: Context) {
  get_context_ffi()
  |> list.filter(fn(c) { c != existing_context })
  |> set_context
}
