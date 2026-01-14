import dromel

pub const dynamic_header_sel = dromel.Selector(selector: "#dynamic-header")

// Generic modal classes (shared by all modals)
pub const modal_search_input_class = dromel.Class(class: "modal-search-input")

pub const modal_left_pane_class = dromel.Class(class: "modal-left-pane")

pub const modal_right_pane_class = dromel.Class(class: "modal-right-pane")

// Topic view container
pub const topic_view_container_id = dromel.Id(id: "topic-view-container")

pub const source_container_class = dromel.Class(class: "source-container")

// Data keys
pub const nav_entry_id = dromel.DataKey(key: "entry-id")

pub const token_topic_id_key = dromel.DataKey(key: "topic")

pub const source_topic_tokens = dromel.Selector(selector: "span[data-topic]")
