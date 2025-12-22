import dromel

pub const dynamic_header_sel = dromel.Selector(selector: "#dynamic-header")

pub const app_id = dromel.Id(id: "app")

pub const contracts_modal_id = dromel.Id(id: "contracts-modal")

pub const contracts_modal_container = dromel.Selector(
  selector: "#contracts-modal > div",
)

pub const contracts_modal_search_input = dromel.Selector(
  selector: "#contracts-modal .modal-search-input",
)

pub const contracts_modal_left_pane = dromel.Selector(
  selector: "#contracts-modal .modal-left-pane",
)

pub const contracts_modal_right_pane = dromel.Selector(
  selector: "#contracts-modal .modal-right-pane",
)

pub const modal_search_input_class = dromel.Class(class: "modal-search-input")

pub const modal_left_pane_class = dromel.Class(class: "modal-left-pane")

pub const modal_right_pane_class = dromel.Class(class: "modal-right-pane")
