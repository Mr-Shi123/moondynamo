///|
pub struct Client {
  config : Config
}

///|
pub fn Client::new(config : Config) -> Client {
  { config, }
}

///|
pub(all) struct QueryResult {
  items : Array[Item]
  last_evaluated_key : Item?
}

///|
fn utc_timestamp() -> String raise {
  let instant = @time.unix(@async.now() / 1000L)
  instant.year().to_string().pad_start(4, '0') +
  instant.month().to_string().pad_start(2, '0') +
  instant.day().to_string().pad_start(2, '0') +
  "T" +
  instant.hour().to_string().pad_start(2, '0') +
  instant.minute().to_string().pad_start(2, '0') +
  instant.second().to_string().pad_start(2, '0') +
  "Z"
}

///|
async fn Client::call(self : Client, action : String, payload : Json) -> Json {
  let request = prepare_request(self.config, action, payload, utc_timestamp())
  let headers : Map[String, String] = Map([])
  for name, value in request.headers {
    // The HTTP client computes Host from the URL; it must match the value
    // that was included in the signature.
    if name.to_lower() != "host" {
      headers[name] = value
    }
  }
  let (response, body) = @http.post(request.url, request.body, headers~)
  parse_response(response.code, response.headers, body.text())
}

///|
fn put_payload(
  table : String,
  item : Item,
  condition_expression~ : String?,
  expression_attribute_values~ : Item,
) -> Json {
  let fields : Map[String, Json] = Map([
    ("TableName", Json::string(table)),
    ("Item", encode_item(item)),
  ])
  if condition_expression is Some(expression) {
    fields["ConditionExpression"] = Json::string(expression)
  }
  if !expression_attribute_values.is_empty() {
    fields["ExpressionAttributeValues"] = encode_item(
      expression_attribute_values,
    )
  }
  Json::object(fields)
}

///|
fn key_payload(table : String, key : Item) -> Map[String, Json] {
  Map([("TableName", Json::string(table)), ("Key", encode_item(key))])
}

///|
fn query_payload(
  table : String,
  key_condition_expression : String,
  expression_attribute_values : Item,
  exclusive_start_key~ : Item?,
  limit~ : Int?,
) -> Json {
  let fields : Map[String, Json] = Map([
    ("TableName", Json::string(table)),
    ("KeyConditionExpression", Json::string(key_condition_expression)),
    ("ExpressionAttributeValues", encode_item(expression_attribute_values)),
  ])
  if exclusive_start_key is Some(key) {
    fields["ExclusiveStartKey"] = encode_item(key)
  }
  if limit is Some(count) {
    fields["Limit"] = @json.to_json(count)
  }
  Json::object(fields)
}

///|
fn parse_get_item(json : Json) -> Item? raise {
  match json {
    Object(fields) =>
      match fields.get("Item") {
        Some(value) => Some(decode_item(value))
        None => None
      }
    _ => raise InvalidResponse("GetItem response must be an object")
  }
}

///|
fn parse_query_result(json : Json) -> QueryResult raise {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidResponse("Query response must be an object")
  }
  let values = match fields.get("Items") {
    Some(Array(values)) => values
    None => []
    Some(_) => raise InvalidResponse("Query response Items must be an array")
  }
  let items : Array[Item] = []
  for value in values {
    items.push(decode_item(value))
  }
  let last_evaluated_key = match fields.get("LastEvaluatedKey") {
    Some(value) => {
      let key = decode_item(value)
      if key.is_empty() {
        None
      } else {
        Some(key)
      }
    }
    None => None
  }
  { items, last_evaluated_key, }
}

///|
pub async fn Client::put_item(
  self : Client,
  table : String,
  item : Item,
  condition_expression? : String,
  expression_attribute_values? : Item,
) -> Unit {
  let values = match expression_attribute_values {
    Some(values) => values
    None => Map([])
  }
  self.call(
    "PutItem",
    put_payload(
      table,
      item,
      condition_expression~,
      expression_attribute_values=values,
    ),
  )
  |> ignore
}

///|
pub async fn Client::get_item(
  self : Client,
  table : String,
  key : Item,
  consistent_read? : Bool = false,
) -> Item? {
  let fields = key_payload(table, key)
  if consistent_read {
    fields["ConsistentRead"] = Json::boolean(true)
  }
  parse_get_item(self.call("GetItem", Json::object(fields)))
}

///|
pub async fn Client::delete_item(
  self : Client,
  table : String,
  key : Item,
  condition_expression? : String,
  expression_attribute_values? : Item,
) -> Unit {
  let fields = key_payload(table, key)
  if condition_expression is Some(expression) {
    fields["ConditionExpression"] = Json::string(expression)
  }
  if expression_attribute_values is Some(values) && !values.is_empty() {
    fields["ExpressionAttributeValues"] = encode_item(values)
  }
  self.call("DeleteItem", Json::object(fields)) |> ignore
}

///|
pub async fn Client::query(
  self : Client,
  table : String,
  key_condition_expression : String,
  expression_attribute_values : Item,
  exclusive_start_key? : Item,
  limit? : Int,
) -> QueryResult {
  parse_query_result(
    self.call(
      "Query",
      query_payload(
        table,
        key_condition_expression,
        expression_attribute_values,
        exclusive_start_key~,
        limit~,
      ),
    ),
  )
}

///|
/// Create an on-demand table with string partition and optional sort keys.
pub async fn Client::create_table(
  self : Client,
  table : String,
  partition_key : String,
  sort_key? : String,
) -> Json {
  let attributes : Array[Json] = [
    Json::object(
      Map([
        ("AttributeName", Json::string(partition_key)),
        ("AttributeType", Json::string("S")),
      ]),
    ),
  ]
  let keys : Array[Json] = [
    Json::object(
      Map([
        ("AttributeName", Json::string(partition_key)),
        ("KeyType", Json::string("HASH")),
      ]),
    ),
  ]
  if sort_key is Some(name) {
    attributes.push(
      Json::object(
        Map([
          ("AttributeName", Json::string(name)),
          ("AttributeType", Json::string("S")),
        ]),
      ),
    )
    keys.push(
      Json::object(
        Map([
          ("AttributeName", Json::string(name)),
          ("KeyType", Json::string("RANGE")),
        ]),
      ),
    )
  }
  self.call(
    "CreateTable",
    Json::object(
      Map([
        ("TableName", Json::string(table)),
        ("AttributeDefinitions", Json::array(attributes)),
        ("KeySchema", Json::array(keys)),
        ("BillingMode", Json::string("PAY_PER_REQUEST")),
      ]),
    ),
  )
}

///|
pub async fn Client::describe_table(self : Client, table : String) -> Json {
  self.call(
    "DescribeTable",
    Json::object(Map([("TableName", Json::string(table))])),
  )
}
