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
pub(all) struct ListTablesResult {
  table_names : Array[String]
  last_evaluated_table_name : String?
}

///|
/// Result of a `batch_get_item` call: the items DynamoDB did return, plus
/// the keys it could not process (usually throttled) for the caller to
/// re-drive in a follow-up call.
pub(all) struct BatchGetResult {
  items : Array[Item]
  unprocessed_keys : Array[Item]
} derive(Eq, Debug)

///|
pub extend BatchGetResult with Eq::{not_equal, equal}

///|
pub extend BatchGetResult with @debug.Debug::{to_repr}

///|
/// One write operation inside a `batch_write_item` call: either overwrite
/// the item under `Put(item)` or remove the item under `Delete(key)`.
pub(all) enum WriteRequest {
  Put(Item)
  Delete(Item)
} derive(Eq, Debug)

///|
pub extend WriteRequest with Eq::{not_equal, equal}

///|
pub extend WriteRequest with @debug.Debug::{to_repr}

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
fn get_item_payload(
  table : String,
  key : Item,
  consistent_read~ : Bool,
  projection_expression~ : String?,
  expression_attribute_names~ : Map[String, String],
) -> Json {
  let fields = key_payload(table, key)
  if consistent_read {
    fields["ConsistentRead"] = Json::boolean(true)
  }
  if projection_expression is Some(expression) {
    fields["ProjectionExpression"] = Json::string(expression)
  }
  if !expression_attribute_names.is_empty() {
    fields["ExpressionAttributeNames"] = encode_names(
      expression_attribute_names,
    )
  }
  Json::object(fields)
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
  limit~ : Int32?,
  projection_expression? : String,
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
  if projection_expression is Some(expression) {
    fields["ProjectionExpression"] = Json::string(expression)
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
  limit~ : Int32?,
  projection_expression? : String,
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
  if projection_expression is Some(expression) {
    fields["ProjectionExpression"] = Json::string(expression)
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
/// DynamoDB accepts at most 100 keys per BatchGetItem request.
const MAX_BATCH_GET_KEYS = 100

///|
/// DynamoDB accepts at most 25 write requests per BatchWriteItem call.
const MAX_BATCH_WRITE_REQUESTS = 25

///|
fn batch_get_payload(
  table : String,
  keys : Array[Item],
  consistent_read~ : Bool?,
) -> Json raise {
  if keys.is_empty() {
    raise InvalidConfig("batch_get_item needs at least one key")
  }
  if keys.length() > MAX_BATCH_GET_KEYS {
    raise InvalidConfig(
      "batch_get_item accepts at most 100 keys per request, got \{keys.length()}",
    )
  }
  let entries : Array[Json] = []
  for key in keys {
    entries.push(encode_item(key))
  }
  let table_entry : Map[String, Json] = Map([("Keys", Json::array(entries))])
  if consistent_read is Some(true) {
    table_entry["ConsistentRead"] = Json::boolean(true)
  }
  let request_items : Map[String, Json] = Map([
    (table, Json::object(table_entry)),
  ])
  Json::object(Map([("RequestItems", Json::object(request_items))]))
}

///|
fn batch_write_payload(
  table : String,
  requests : Array[WriteRequest],
) -> Json raise {
  if requests.is_empty() {
    raise InvalidConfig("batch_write_item needs at least one write request")
  }
  if requests.length() > MAX_BATCH_WRITE_REQUESTS {
    raise InvalidConfig(
      "batch_write_item accepts at most 25 write requests per call, got \{requests.length()}",
    )
  }
  let entries : Array[Json] = []
  for request in requests {
    let entry = match request {
      Put(item) =>
        Json::object(
          Map([("PutRequest", Json::object(Map([("Item", encode_item(item))])))]),
        )
      Delete(key) =>
        Json::object(
          Map([
            ("DeleteRequest", Json::object(Map([("Key", encode_item(key))]))),
          ]),
        )
    }
    entries.push(entry)
  }
  let request_items : Map[String, Json] = Map([(table, Json::array(entries))])
  Json::object(Map([("RequestItems", Json::object(request_items))]))
}

///|
fn parse_batch_get_result(table : String, json : Json) -> BatchGetResult raise {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidResponse("BatchGetItem response must be an object")
  }
  let items : Array[Item] = []
  match fields.get("Responses") {
    Some(Object(responses)) =>
      match responses.get(table) {
        Some(Array(values)) =>
          for value in values {
            items.push(decode_item(value))
          }
        Some(_) =>
          raise InvalidResponse("BatchGetItem Responses entry must be an array")
        None => ()
      }
    Some(_) => raise InvalidResponse("BatchGetItem Responses must be an object")
    None => ()
  }
  let unprocessed_keys : Array[Item] = []
  match fields.get("UnprocessedKeys") {
    Some(Object(tables)) =>
      match tables.get(table) {
        Some(Object(entry)) =>
          match entry.get("Keys") {
            Some(Array(values)) =>
              for value in values {
                unprocessed_keys.push(decode_item(value))
              }
            Some(_) =>
              raise InvalidResponse(
                "UnprocessedKeys entry Keys must be an array",
              )
            None => ()
          }
        Some(_) =>
          raise InvalidResponse("UnprocessedKeys entry must be an object")
        None => ()
      }
    Some(_) => raise InvalidResponse("UnprocessedKeys must be an object")
    None => ()
  }
  { items, unprocessed_keys, }
}

///|
fn parse_batch_write_result(
  table : String,
  json : Json,
) -> Array[WriteRequest] raise {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidResponse("BatchWriteItem response must be an object")
  }
  let unprocessed : Array[WriteRequest] = []
  match fields.get("UnprocessedItems") {
    Some(Object(tables)) =>
      match tables.get(table) {
        Some(Array(values)) =>
          for value in values {
            unprocessed.push(decode_write_request(value))
          }
        Some(_) =>
          raise InvalidResponse(
            "BatchWriteItem UnprocessedItems entry must be an array",
          )
        None => ()
      }
    Some(_) =>
      raise InvalidResponse("BatchWriteItem UnprocessedItems must be an object")
    None => ()
  }
  unprocessed
}

///|
fn decode_write_request(json : Json) -> WriteRequest raise {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidResponse("write request must be an object")
  }
  match fields.get("PutRequest") {
    Some(Object(put)) =>
      match put.get("Item") {
        Some(item) => Put(decode_item(item))
        None => raise InvalidResponse("PutRequest must carry an Item")
      }
    _ =>
      match fields.get("DeleteRequest") {
        Some(Object(delete)) =>
          match delete.get("Key") {
            Some(key) => Delete(decode_item(key))
            None => raise InvalidResponse("DeleteRequest must carry a Key")
          }
        _ =>
          raise InvalidResponse(
            "write request must be a PutRequest or DeleteRequest",
          )
      }
  }
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
fn list_tables_payload(
  limit~ : Int32?,
  exclusive_start_table_name~ : String?,
) -> Json raise {
  let fields : Map[String, Json] = Map([])
  if limit is Some(count) {
    if count < 1 || count > 100 {
      raise InvalidConfig("ListTables limit must be between 1 and 100")
    }
    fields["Limit"] = @json.to_json(count)
  }
  if exclusive_start_table_name is Some(name) {
    fields["ExclusiveStartTableName"] = Json::string(name)
  }
  Json::object(fields)
}

///|
fn parse_list_tables_result(json : Json) -> ListTablesResult raise {
  let fields = match json {
    Object(fields) => fields
    _ => raise InvalidResponse("ListTables response must be an object")
  }
  let table_names : Array[String] = []
  match fields.get("TableNames") {
    Some(Array(values)) =>
      for value in values {
        match value {
          String(name) => table_names.push(name)
          _ =>
            raise InvalidResponse("ListTables TableNames must contain strings")
        }
      }
    Some(_) => raise InvalidResponse("ListTables TableNames must be an array")
    None => ()
  }
  let last_evaluated_table_name = match fields.get("LastEvaluatedTableName") {
    Some(String(name)) => Some(name)
    Some(_) =>
      raise InvalidResponse(
        "ListTables LastEvaluatedTableName must be a string",
      )
    None => None
  }
  { table_names, last_evaluated_table_name, }
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
/// Read an item by key. Use `projection_expression` to request only selected
/// attributes and `expression_attribute_names` for reserved attribute names.
pub async fn Client::get_item(
  self : Client,
  table : String,
  key : Item,
  consistent_read~ : Bool = false,
  projection_expression? : String,
  expression_attribute_names? : Map[String, String],
) -> Item? {
  let names = match expression_attribute_names {
    Some(names) => names
    None => Map([])
  }
  parse_get_item(
    self.call(
      "GetItem",
      get_item_payload(
        table,
        key,
        consistent_read~,
        projection_expression~,
        expression_attribute_names=names,
      ),
    ),
  )
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
/// Query matching items, optionally requesting only selected attributes with
/// `projection_expression`.
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
  limit? : Int32,
  expression_attribute_names? : Map[String, String],
  projection_expression? : String,
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
        projection_expression?,
      ),
    ),
  )
}

///|
/// Read the items of a table or, via `index_name`, of a secondary index,
/// page by page. `filter_expression` drops items server-side; because the
/// filter applies after `limit` is counted, a page can come back empty while
/// `last_evaluated_key` is still present — keep following it until `None`.
/// Use `projection_expression` to request only selected attributes.
pub async fn Client::scan(
  self : Client,
  table : String,
  filter_expression? : String,
  expression_attribute_values? : Item,
  expression_attribute_names? : Map[String, String],
  index_name? : String,
  consistent_read? : Bool,
  exclusive_start_key? : Item,
  limit? : Int32,
  projection_expression? : String,
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
        projection_expression?,
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

///|
/// List table names in the configured account and region. Pass the returned
/// `last_evaluated_table_name` as `exclusive_start_table_name` to fetch the
/// next page. DynamoDB returns at most 100 names per page.
pub async fn Client::list_tables(
  self : Client,
  limit? : Int32,
  exclusive_start_table_name? : String,
) -> ListTablesResult {
  parse_list_tables_result(
    self.call(
      "ListTables",
      list_tables_payload(limit~, exclusive_start_table_name~),
    ),
  )
}

///|
/// Read up to 100 items in one round trip. Keys that do not exist are simply
/// absent from `items`; keys DynamoDB could not process (usually throttled)
/// come back in `unprocessed_keys` — re-drive them in a follow-up call.
/// Consistent reads can be requested for the base table with
/// `consistent_read`.
pub async fn Client::batch_get_item(
  self : Client,
  table : String,
  keys : Array[Item],
  consistent_read? : Bool,
) -> BatchGetResult {
  parse_batch_get_result(
    table,
    self.call("BatchGetItem", batch_get_payload(table, keys, consistent_read~)),
  )
}

///|
/// Apply up to 25 puts and deletes in one round trip. Requests DynamoDB
/// could not process come back as the return value — re-drive them in a
/// follow-up call. A batch write is not atomic and cannot update the same
/// item twice in one call; use transactions when those guarantees matter.
pub async fn Client::batch_write_item(
  self : Client,
  table : String,
  requests : Array[WriteRequest],
) -> Array[WriteRequest] {
  parse_batch_write_result(
    table,
    self.call("BatchWriteItem", batch_write_payload(table, requests)),
  )
}
