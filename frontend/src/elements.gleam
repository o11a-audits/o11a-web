pub type Element {
  AnchorElement(selector: String)
  Class(selector: String, class: String)
  Id(selector: String, id: String)
}

pub const dynamic_header = AnchorElement(selector: "#dynamic-header")
