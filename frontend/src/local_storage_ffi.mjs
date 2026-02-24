import { Result$Ok, Result$Error } from "./gleam.mjs";

export function get_item(key) {
  let val = localStorage.getItem(key);
  if (val === null) {
    return Result$Error();
  }
  return Result$Ok(val);
}

export function set_item(key, value) {
  localStorage.setItem(key, value);
}
