import { Result$Ok, Result$Error } from "./gleam.mjs";

let contracts_promise;

export function set_contracts_promise(promise) {
  contracts_promise = promise;
}

export function get_contracts_promise() {
  if (!contracts_promise) {
    return Result$Error();
  }
  return Result$Ok(contracts_promise);
}

let contracts;

export function set_contracts(val) {
  contracts = val;
}

export function get_contracts() {
  if (!contracts) {
    return Result$Error();
  }
  return Result$Ok(contracts);
}
