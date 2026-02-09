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

pub const code_style_class = dromel.Class(class: "code-style")

// Data keys
pub const token_topic_id_key = dromel.DataKey(key: "topic")

pub fn topic_selector(topic_id: String) {
  dromel.Selector(selector: "[data-topic-id=\"" <> topic_id <> "\"]")
}

pub const topic_tokens_class = dromel.Class(class: "topic-token")
