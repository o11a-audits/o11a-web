import dromel

pub const dynamic_header_sel = dromel.Selector(selector: "#dynamic-header")

// Generic modal classes (shared by all modals)
pub const modal_search_input_class = dromel.Class(class: "modal-search-input")

pub const modal_left_pane_class = dromel.Class(class: "modal-left-pane")

pub const modal_right_pane_class = dromel.Class(class: "modal-right-pane")

const source_container_class_name = "source-container"

pub const source_container_class = dromel.Class(
  class: source_container_class_name,
)

// Data keys
pub const token_topic_id_key = dromel.DataKey(key: "topic")

pub const source_topic_tokens = dromel.Selector(
  selector: "div[data-topic]:not(."
    <> source_container_class_name
    <> "), span[data-topic]:not(."
    <> source_container_class_name
    <> ")",
)
