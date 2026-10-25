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
/// Retry attempts allowed after the first call fails with a transient error.
const MAX_RETRIES = 2

///|
/// Whether a failed attempt is worth retrying: throttling and throughput
/// errors (which arrive as HTTP 400 with a service-specific code) plus
/// rate-limit and transient server statuses (429/500/503). Config mistakes,
/// malformed responses, and transport failures surface immediately.
fn is_retryable(error : Error) -> Bool {
  match error {
    Service(status, code, _, _) => {
      let transient_status = status == 429 || status == 500 || status == 503
      let throttled = match code {
        "ProvisionedThroughputExceededException"
        | "ThrottlingException"
        | "RequestLimitExceeded"
        | "ServiceUnavailable" => true
        _ => false
      }
      transient_status || throttled
    }
    _ => false
  }
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
  @async.retry(
    ExponentialDelay(initial=100, factor=2.0, maximum=2000),
    max_retry=MAX_RETRIES,
    fatal_error=fn(error) { !is_retryable(error) },
  ) <| () => {
    let (response, body) = @http.post(request.url, request.body, headers~)
    parse_response(response.code, response.headers, body.text())
  }
}

///|
/// Which attributes `UpdateItem` should return, mirroring DynamoDB's
/// `ReturnValues` parameter.
pub(all) enum ReturnValues {
  Nothing
  AllOld
  AllNew
  UpdatedOld
  UpdatedNew
} derive(Eq, Debug)

///|
pub extend ReturnValues with Eq::{not_equal, equal}

///|
pub extend ReturnValues with @debug.Debug::{to_repr}

///|
fn ReturnValues::to_wire(self : ReturnValues) -> String {
  match self {
    Nothing => "NONE"
    AllOld => "ALL_OLD"
    AllNew => "ALL_NEW"
    UpdatedOld => "UPDATED_OLD"
    UpdatedNew => "UPDATED_NEW"
  }
}

///|
/// Expression attribute name placeholders (`#name` -> real attribute name),
/// the escape hatch for attribute names that collide with DynamoDB
/// reserved words.
fn encode_names(names : Map[String, String]) -> Json {
  let fields : Map[String, Json] = Map([])
  for placeholder, name in names {
    fields[placeholder] = Json::string(name)
  }
  Json::object(fields)
}

///|
fn put_payload(
  table : String,
  item : Item,
  condition_expression~ : String?,
  expression_attribute_values~ : Item,
  expression_attribute_names~ : Map[String, String],
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
  if !expression_attribute_names.is_empty() {
    fields["ExpressionAttributeNames"] = encode_names(
      expression_attribute_names,
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
  filter_expression~ : String?,
  index_name~ : String?,
  descending~ : Bool?,
  consistent_read~ : Bool?,
  expression_attribute_names~ : Map[String, String],
  exclusive_start_key~ : Item?,
  limit~ : Int?,
) -> Json {
  let fields : Map[String, Json] = Map([
    ("TableName", Json::string(table)),
    ("KeyConditionExpression", Json::string(key_condition_expression)),
  ])
  if index_name is Some(name) {
    fields["IndexName"] = Json::string(name)
  }
  if filter_expression is Some(expression) {
    fields["FilterExpression"] = Json::string(expression)
  }
  fields["ExpressionAttributeValues"] = encode_item(expression_attribute_values)
  if !expression_attribute_names.is_empty() {
    fields["ExpressionAttributeNames"] = encode_names(
      expression_attribute_names,
    )
  }
  if exclusive_start_key is Some(key) {
    fields["ExclusiveStartKey"] = encode_item(key)
  }
  if limit is Some(count) {
    fields["Limit"] = @json.to_json(count)
  }
  if descending is Some(true) {
    fields["ScanIndexForward"] = Json::boolean(false)
  }
  if consistent_read is Some(true) {
    fields["ConsistentRead"] = Json::boolean(true)
  }
  Json::object(fields)
}

///|
fn scan_payload(
  table : String,
  filter_expression~ : String?,
  expression_attribute_values~ : Item,
  expression_attribute_names~ : Map[String, String],
  index_name~ : String?,
  consistent_read~ : Bool?,
  exclusive_start_key~ : Item?,
  limit~ : Int?,
) -> Json {
  let fields : Map[String, Json] = Map([("TableName", Json::string(table))])
  if index_name is Some(name) {
    fields["IndexName"] = Json::string(name)
  }
  if filter_expression is Some(expression) {
    fields["FilterExpression"] = Json::string(expression)
  }
  if !expression_attribute_values.is_empty() {
    fields["ExpressionAttributeValues"] = encode_item(
      expression_attribute_values,
    )
  }
  if !expression_attribute_names.is_empty() {
    fields["ExpressionAttributeNames"] = encode_names(
      expression_attribute_names,
    )
  }
  if exclusive_start_key is Some(key) {
    fields["ExclusiveStartKey"] = encode_item(key)
  }
  if limit is Some(count) {
    fields["Limit"] = @json.to_json(count)
  }
  if consistent_read is Some(true) {
    fields["ConsistentRead"] = Json::boolean(true)
  }
  Json::object(fields)
}

///|
fn update_payload(
  table : String,
  key : Item,
  update_expression : String,
  expression_attribute_values~ : Item,
  expression_attribute_names~ : Map[String, String],
  return_values~ : ReturnValues?,
) -> Json {
  let fields : Map[String, Json] = Map([
    ("TableName", Json::string(table)),
    ("Key", encode_item(key)),
    ("UpdateExpression", Json::string(update_expression)),
  ])
  if !expression_attribute_values.is_empty() {
    fields["ExpressionAttributeValues"] = encode_item(
      expression_attribute_values,
    )
  }
  if !expression_attribute_names.is_empty() {
    fields["ExpressionAttributeNames"] = encode_names(
      expression_attribute_names,
    )
  }
  if return_values is Some(values) {
    fields["ReturnValues"] = Json::string(values.to_wire())
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
fn parse_update_result(json : Json) -> Item? raise {
  match json {
    Object(fields) =>
      match fields.get("Attributes") {
        Some(value) => Some(decode_item(value))
        None => None
      }
    _ => raise InvalidResponse("UpdateItem response must be an object")
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
  expression_attribute_names? : Map[String, String],
) -> Unit {
  let values = match expression_attribute_values {
    Some(values) => values
    None => Map([])
  }
  let names = match expression_attribute_names {
    Some(names) => names
    None => Map([])
  }
  self.call(
    "PutItem",
    put_payload(
      table,
      item,
      condition_expression~,
      expression_attribute_values=values,
      expression_attribute_names=names,
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
  expression_attribute_names? : Map[String, String],
) -> Unit {
  let fields = key_payload(table, key)
  if condition_expression is Some(expression) {
    fields["ConditionExpression"] = Json::string(expression)
  }
  if expression_attribute_values is Some(values) && !values.is_empty() {
    fields["ExpressionAttributeValues"] = encode_item(values)
  }
  if expression_attribute_names is Some(names) && !names.is_empty() {
    fields["ExpressionAttributeNames"] = encode_names(names)
  }
  self.call("DeleteItem", Json::object(fields)) |> ignore
}

///|
/// Apply an `UpdateExpression` (e.g. `SET pages = :p`, `ADD views :one`,
/// `REMOVE note`) to the item identified by `key`. Pass `return_values` to
/// get the resulting attributes back; without it the reply carries none and
/// the result is `None`.
pub async fn Client::update_item(
  self : Client,
  table : String,
  key : Item,
  update_expression : String,
  expression_attribute_values? : Item,
  expression_attribute_names? : Map[String, String],
  return_values? : ReturnValues,
) -> Item? {
  let values = match expression_attribute_values {
    Some(values) => values
    None => Map([])
  }
  let names = match expression_attribute_names {
    Some(names) => names
    None => Map([])
  }
  parse_update_result(
    self.call(
      "UpdateItem",
      update_payload(
        table,
        key,
        update_expression,
        expression_attribute_values=values,
        expression_attribute_names=names,
        return_values~,
      ),
    ),
  )
}

///|
pub async fn Client::query(
  self : Client,
  table : String,
  key_condition_expression : String,
  expression_attribute_values : Item,
  filter_expression? : String,
  index_name? : String,
  descending? : Bool,
  consistent_read? : Bool,
  exclusive_start_key? : Item,
  limit? : Int,
  expression_attribute_names? : Map[String, String],
) -> QueryResult {
  let names = match expression_attribute_names {
    Some(names) => names
    None => Map([])
  }
  parse_query_result(
    self.call(
      "Query",
      query_payload(
        table,
        key_condition_expression,
        expression_attribute_values,
        filter_expression~,
        index_name~,
        descending~,
        consistent_read~,
        expression_attribute_names=names,
        exclusive_start_key~,
        limit~,
      ),
    ),
  )
}

///|
/// Read the items of a table or, via `index_name`, of a secondary index,
/// page by page. `filter_expression` drops items server-side; because the
/// filter applies after `limit` is counted, a page can come back empty while
/// `last_evaluated_key` is still present — keep following it until `None`.
pub async fn Client::scan(
  self : Client,
  table : String,
  filter_expression? : String,
  expression_attribute_values? : Item,
  expression_attribute_names? : Map[String, String],
  index_name? : String,
  consistent_read? : Bool,
  exclusive_start_key? : Item,
  limit? : Int,
) -> QueryResult {
  let values = match expression_attribute_values {
    Some(values) => values
    None => Map([])
  }
  let names = match expression_attribute_names {
    Some(names) => names
    None => Map([])
  }
  parse_query_result(
    self.call(
      "Scan",
      scan_payload(
        table,
        filter_expression~,
        expression_attribute_values=values,
        expression_attribute_names=names,
        index_name~,
        consistent_read~,
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
