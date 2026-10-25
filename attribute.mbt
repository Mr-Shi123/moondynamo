///|
/// DynamoDB's wire attribute types. Numbers stay as decimal text to avoid
/// losing precision when they pass through JSON.
pub(all) enum AttributeValue {
  Text(String)
  Number(String)
  Binary(Bytes)
  BoolValue(Bool)
  NullValue
  ListValue(Array[AttributeValue])
  ObjectValue(Map[String, AttributeValue])
  StringSet(Array[String])
  NumberSet(Array[String])
  BinarySet(Array[Bytes])
} derive(Eq, Debug)

///|
pub extend AttributeValue with Eq::{not_equal, equal}

///|
pub extend AttributeValue with @debug.Debug::{to_repr}

///|
pub type Item = Map[String, AttributeValue]

///|
pub(all) suberror CodecError {
  InvalidAttribute(String)
}

///|
fn tagged(tag : String, value : Json) -> Json {
  Json::object(Map([(tag, value)]))
}

///|
pub fn encode_attribute(value : AttributeValue) -> Json {
  match value {
    Text(text) => tagged("S", Json::string(text))
    Number(number) => tagged("N", Json::string(number))
    Binary(bytes) => tagged("B", Json::string(@base64.encode(bytes)))
    BoolValue(true) => tagged("BOOL", Json::boolean(true))
    BoolValue(false) => tagged("BOOL", Json::boolean(false))
    NullValue => tagged("NULL", Json::boolean(true))
    ListValue(items) => tagged("L", Json::array(items.map(encode_attribute)))
    ObjectValue(fields) => tagged("M", encode_item(fields))
    StringSet(values) =>
      tagged("SS", Json::array(values.map(fn(s) { Json::string(s) })))
    NumberSet(values) =>
      tagged("NS", Json::array(values.map(fn(s) { Json::string(s) })))
    BinarySet(values) =>
      tagged(
        "BS",
        Json::array(values.map(fn(b) { Json::string(@base64.encode(b)) })),
      )
  }
}

///|
pub fn encode_item(item : Item) -> Json {
  let fields : Map[String, Json] = Map([])
  for key, value in item {
    fields[key] = encode_attribute(value)
  }
  Json::object(fields)
}

///|
fn string_value(value : Json, tag : String) -> String raise CodecError {
  match value {
    String(text) => text
    _ => raise InvalidAttribute("\{tag} must contain a string")
  }
}

///|
fn binary_value(value : Json, tag : String) -> Bytes raise CodecError {
  let text = string_value(value, tag)
  @base64.decode(text) catch {
    _ => raise InvalidAttribute("\{tag} must contain base64")
  }
}

///|
fn string_array(value : Json, tag : String) -> Array[String] raise CodecError {
  match value {
    Array(values) => {
      let result : Array[String] = []
      for value in values {
        result.push(string_value(value, tag))
      }
      result
    }
    _ => raise InvalidAttribute("\{tag} must contain an array")
  }
}

///|
pub fn decode_attribute(json : Json) -> AttributeValue raise CodecError {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidAttribute("attribute must be an object")
  }
  if fields.length() != 1 {
    raise InvalidAttribute("attribute must have exactly one type tag")
  }
  match fields.iter().next() {
    Some(("S", value)) => Text(string_value(value, "S"))
    Some(("N", value)) => Number(string_value(value, "N"))
    Some(("B", value)) => Binary(binary_value(value, "B"))
    Some(("BOOL", True)) => BoolValue(true)
    Some(("BOOL", False)) => BoolValue(false)
    Some(("NULL", True)) => NullValue
    Some(("L", Array(values))) => {
      let result : Array[AttributeValue] = []
      for value in values {
        result.push(decode_attribute(value))
      }
      ListValue(result)
    }
    Some(("M", value)) => ObjectValue(decode_item(value))
    Some(("SS", value)) => StringSet(string_array(value, "SS"))
    Some(("NS", value)) => NumberSet(string_array(value, "NS"))
    Some(("BS", Array(values))) => {
      let result : Array[Bytes] = []
      for value in values {
        result.push(binary_value(value, "BS"))
      }
      BinarySet(result)
    }
    Some((tag, _)) => raise InvalidAttribute("invalid value for tag \{tag}")
    None => raise InvalidAttribute("attribute is empty")
  }
}

///|
pub fn decode_item(json : Json) -> Item raise CodecError {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidAttribute("item must be an object")
  }
  let item : Item = Map([])
  for name, value in fields {
    item[name] = decode_attribute(value)
  }
  item
}
