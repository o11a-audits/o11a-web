import gleam/int

const storage_key = "o11a_user_id"

@external(javascript, "../local_storage_ffi.mjs", "get_item")
fn get_local_storage(key: String) -> Result(String, Nil)

@external(javascript, "../local_storage_ffi.mjs", "set_item")
fn set_local_storage(key: String, value: String) -> Nil

pub fn id() -> Int {
  case get_local_storage(storage_key) {
    Ok(value) ->
      case int.parse(value) {
        Ok(n) if n >= 10 && n <= 99 -> n
        _ -> generate_and_store()
      }
    Error(_) -> generate_and_store()
  }
}

fn generate_and_store() -> Int {
  let new_id = int.random(90) + 10
  set_local_storage(storage_key, int.to_string(new_id))
  new_id
}
