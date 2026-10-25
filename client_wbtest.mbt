///|
test "put payload carries a conditional expression and typed value" {
  let payload = put_payload(
    "books",
    Map([("pk", Text("book#1"))]),
    condition_expression=Some("attribute_not_exists(pk)"),
    expression_attribute_values=Map([]),
    expression_attribute_names=Map([]),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"Item\":{\"pk\":{\"S\":\"book#1\"}},\"ConditionExpression\":\"attribute_not_exists(pk)\"}",
  )
}

///|
test "put payload sends name placeholders for reserved words" {
  let payload = put_payload(
    "books",
    Map([("pk", Text("book#1"))]),
    condition_expression=Some("attribute_not_exists(#pk)"),
    expression_attribute_values=Map([]),
    expression_attribute_names=Map([("#pk", "pk")]),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"Item\":{\"pk\":{\"S\":\"book#1\"}},\"ConditionExpression\":\"attribute_not_exists(#pk)\",\"ExpressionAttributeNames\":{\"#pk\":\"pk\"}}",
  )
}

///|
test "query response exposes continuation key" {
  let result = parse_query_result(
    @json.parse(
      "{\"Items\":[{\"pk\":{\"S\":\"book#1\"}}],\"LastEvaluatedKey\":{\"pk\":{\"S\":\"book#1\"}}}",
    ),
  )
  assert_eq(result.items.length(), 1)
  assert_eq(result.items[0].get("pk"), Some(Text("book#1")))
  assert_eq(result.last_evaluated_key, Some(Map([("pk", Text("book#1"))])))
}

///|
test "query response may omit Items while keeping a continuation key" {
  let result = parse_query_result(
    @json.parse(
      "{\"Count\":0,\"ScannedCount\":1,\"LastEvaluatedKey\":{\"pk\":{\"S\":\"book#1\"}}}",
    ),
  )
  assert_eq(result.items.length(), 0)
  assert_eq(result.last_evaluated_key, Some(Map([("pk", Text("book#1"))])))
}

///|
test "query payload sends the pagination key" {
  let payload = query_payload(
    "books",
    "pk = :pk",
    Map([(":pk", Text("book#1"))]),
    filter_expression=None,
    index_name=None,
    descending=None,
    consistent_read=None,
    expression_attribute_names=Map([]),
    exclusive_start_key=Some(Map([("pk", Text("book#0"))])),
    limit=Some(10),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"KeyConditionExpression\":\"pk = :pk\",\"ExpressionAttributeValues\":{\":pk\":{\"S\":\"book#1\"}},\"ExclusiveStartKey\":{\"pk\":{\"S\":\"book#0\"}},\"Limit\":10}",
  )
}

///|
test "query payload sends filter expression and name placeholders" {
  let payload = query_payload(
    "books",
    "pk = :pk",
    Map([(":pk", Text("user#1")), (":st", Text("active"))]),
    filter_expression=Some("#st = :st"),
    index_name=None,
    descending=None,
    consistent_read=None,
    expression_attribute_names=Map([("#st", "status")]),
    exclusive_start_key=None,
    limit=None,
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"KeyConditionExpression\":\"pk = :pk\",\"FilterExpression\":\"#st = :st\",\"ExpressionAttributeValues\":{\":pk\":{\"S\":\"user#1\"},\":st\":{\"S\":\"active\"}},\"ExpressionAttributeNames\":{\"#st\":\"status\"}}",
  )
}

///|
test "query payload targets an index newest-first" {
  let payload = query_payload(
    "books",
    "#st = :st",
    Map([(":st", Text("active"))]),
    filter_expression=None,
    index_name=Some("status-index"),
    descending=Some(true),
    consistent_read=None,
    expression_attribute_names=Map([("#st", "status")]),
    exclusive_start_key=None,
    limit=None,
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"KeyConditionExpression\":\"#st = :st\",\"IndexName\":\"status-index\",\"ExpressionAttributeValues\":{\":st\":{\"S\":\"active\"}},\"ExpressionAttributeNames\":{\"#st\":\"status\"},\"ScanIndexForward\":false}",
  )
}

///|
test "query payload forces a consistent read when asked" {
  let payload = query_payload(
    "books",
    "pk = :pk",
    Map([(":pk", Text("book#1"))]),
    filter_expression=None,
    index_name=None,
    descending=None,
    consistent_read=Some(true),
    expression_attribute_names=Map([]),
    exclusive_start_key=None,
    limit=None,
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"KeyConditionExpression\":\"pk = :pk\",\"ExpressionAttributeValues\":{\":pk\":{\"S\":\"book#1\"}},\"ConsistentRead\":true}",
  )
}

///|
test "scan payload starts from just the table name" {
  let payload = scan_payload(
    "books",
    filter_expression=None,
    expression_attribute_values=Map([]),
    expression_attribute_names=Map([]),
    index_name=None,
    consistent_read=None,
    exclusive_start_key=None,
    limit=None,
  )
  assert_eq(payload.stringify(), "{\"TableName\":\"books\"}")
}

///|
test "scan payload carries filter, index, and paging" {
  let payload = scan_payload(
    "books",
    filter_expression=Some("pages <= :max"),
    expression_attribute_values=Map([(":max", Number("500"))]),
    expression_attribute_names=Map([]),
    index_name=Some("pages-index"),
    consistent_read=Some(true),
    exclusive_start_key=Some(Map([("pk", Text("book#9"))])),
    limit=Some(100),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"IndexName\":\"pages-index\",\"FilterExpression\":\"pages <= :max\",\"ExpressionAttributeValues\":{\":max\":{\"N\":\"500\"}},\"ExclusiveStartKey\":{\"pk\":{\"S\":\"book#9\"}},\"Limit\":100,\"ConsistentRead\":true}",
  )
}

///|
test "update payload carries expression, names, and return values" {
  let payload = update_payload(
    "books",
    Map([("pk", Text("book#1"))]),
    "SET #st = :st ADD pages :inc",
    expression_attribute_values=Map([
      (":st", Text("archived")),
      (":inc", Number("5")),
    ]),
    expression_attribute_names=Map([("#st", "status")]),
    return_values=Some(UpdatedNew),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"Key\":{\"pk\":{\"S\":\"book#1\"}},\"UpdateExpression\":\"SET #st = :st ADD pages :inc\",\"ExpressionAttributeValues\":{\":st\":{\"S\":\"archived\"},\":inc\":{\"N\":\"5\"}},\"ExpressionAttributeNames\":{\"#st\":\"status\"},\"ReturnValues\":\"UPDATED_NEW\"}",
  )
}

///|
test "update payload omits empty expression maps" {
  let payload = update_payload(
    "books",
    Map([("pk", Text("book#1"))]),
    "REMOVE note",
    expression_attribute_values=Map([]),
    expression_attribute_names=Map([]),
    return_values=None,
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"Key\":{\"pk\":{\"S\":\"book#1\"}},\"UpdateExpression\":\"REMOVE note\"}",
  )
}

///|
test "update result returns attributes when present" {
  let result = parse_update_result(
    @json.parse(
      "{\"Attributes\":{\"pk\":{\"S\":\"book#1\"},\"pages\":{\"N\":\"200\"}}}",
    ),
  )
  assert_eq(
    result,
    Some(Map([("pk", Text("book#1")), ("pages", Number("200"))])),
  )
}

///|
test "update result without attributes is none" {
  assert_eq(parse_update_result(@json.parse("{}")), None)
}

///|
test "return values map to wire strings" {
  assert_eq(Nothing.to_wire(), "NONE")
  assert_eq(AllOld.to_wire(), "ALL_OLD")
  assert_eq(AllNew.to_wire(), "ALL_NEW")
  assert_eq(UpdatedOld.to_wire(), "UPDATED_OLD")
  assert_eq(UpdatedNew.to_wire(), "UPDATED_NEW")
}

///|
test "retry policy covers throttling and transient statuses" {
  assert_eq(
    is_retryable(
      Service(400, "ProvisionedThroughputExceededException", "throttled", None),
    ),
    true,
  )
  assert_eq(
    is_retryable(Service(429, "ThrottlingException", "slow down", None)),
    true,
  )
  assert_eq(
    is_retryable(Service(503, "ServiceUnavailable", "unavailable", None)),
    true,
  )
  assert_eq(
    is_retryable(Service(500, "InternalServerError", "boom", None)),
    true,
  )
  assert_eq(
    is_retryable(Service(400, "ConditionalCheckFailedException", "nope", None)),
    false,
  )
  assert_eq(
    is_retryable(Service(400, "ValidationException", "bad input", None)),
    false,
  )
  assert_eq(is_retryable(InvalidConfig("bad endpoint")), false)
  assert_eq(is_retryable(InvalidResponse("bad body")), false)
}

///|
test "missing item response means no match" {
  assert_eq(parse_get_item(@json.parse("{}")), None)
}

///|
test "batch get payload wraps keys in the multi-table request shape" {
  let payload = batch_get_payload(
    "books",
    [Map([("pk", Text("book#1"))]), Map([("pk", Text("book#2"))])],
    consistent_read=None,
  )
  assert_eq(
    payload.stringify(),
    "{\"RequestItems\":{\"books\":{\"Keys\":[{\"pk\":{\"S\":\"book#1\"}},{\"pk\":{\"S\":\"book#2\"}}]}}}",
  )
}

///|
test "batch get payload can request a consistent read" {
  let payload = batch_get_payload(
    "books",
    [Map([("pk", Text("book#1"))])],
    consistent_read=Some(true),
  )
  assert_eq(
    payload.stringify(),
    "{\"RequestItems\":{\"books\":{\"Keys\":[{\"pk\":{\"S\":\"book#1\"}}],\"ConsistentRead\":true}}}",
  )
}

///|
/// Returns whether the body raised any error.
fn raises(body : () -> Unit raise) -> Bool {
  try {
    body()
    false
  } catch {
    _ => true
  }
}

///|
test "batch get rejects empty and oversized key lists" {
  let empty : Array[Item] = []
  assert_eq(
    raises(() => {
      batch_get_payload("books", empty, consistent_read=None) |> ignore
    }),
    true,
  )
  let too_many : Array[Item] = Array::make(101, Map([("pk", Text("book#1"))]))
  assert_eq(
    raises(() => {
      batch_get_payload("books", too_many, consistent_read=None) |> ignore
    }),
    true,
  )
}

///|
test "batch write payload carries put and delete requests" {
  let payload = batch_write_payload("books", [
    Put(Map([("pk", Text("book#9")), ("pages", Number("42"))])),
    Delete(Map([("pk", Text("book#1"))])),
  ])
  assert_eq(
    payload.stringify(),
    "{\"RequestItems\":{\"books\":[{\"PutRequest\":{\"Item\":{\"pk\":{\"S\":\"book#9\"},\"pages\":{\"N\":\"42\"}}}},{\"DeleteRequest\":{\"Key\":{\"pk\":{\"S\":\"book#1\"}}}}]}}",
  )
}

///|
test "batch write rejects empty and oversized request lists" {
  let empty : Array[WriteRequest] = []
  assert_eq(raises(() => batch_write_payload("books", empty) |> ignore), true)
  let too_many : Array[WriteRequest] = Array::make(
    26,
    Delete(Map([("pk", Text("book#1"))])),
  )
  assert_eq(
    raises(() => batch_write_payload("books", too_many) |> ignore),
    true,
  )
}

///|
test "batch get result separates items from unprocessed keys" {
  let result = parse_batch_get_result(
    "books",
    @json.parse(
      "{\"Responses\":{\"books\":[{\"pk\":{\"S\":\"book#1\"}}]},\"UnprocessedKeys\":{\"books\":{\"Keys\":[{\"pk\":{\"S\":\"book#2\"}}]}}}",
    ),
  )
  assert_eq(result.items, [Map([("pk", Text("book#1"))])])
  assert_eq(result.unprocessed_keys, [Map([("pk", Text("book#2"))])])
}

///|
test "batch get result tolerates missing sections" {
  let result = parse_batch_get_result("books", @json.parse("{}"))
  assert_eq(result.items.length(), 0)
  assert_eq(result.unprocessed_keys.length(), 0)
}

///|
test "batch write result returns unprocessed put and delete requests" {
  let unprocessed = parse_batch_write_result(
    "books",
    @json.parse(
      "{\"UnprocessedItems\":{\"books\":[{\"PutRequest\":{\"Item\":{\"pk\":{\"S\":\"book#8\"}}}},{\"DeleteRequest\":{\"Key\":{\"pk\":{\"S\":\"book#7\"}}}}]}}",
    ),
  )
  assert_eq(unprocessed, [
    Put(Map([("pk", Text("book#8"))])),
    Delete(Map([("pk", Text("book#7"))])),
  ])
}

///|
test "batch write result is empty without unprocessed items" {
  let unprocessed = parse_batch_write_result("books", @json.parse("{}"))
  assert_eq(unprocessed.length(), 0)
}
