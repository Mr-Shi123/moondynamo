///|
test "put payload carries a conditional expression and typed value" {
  let payload = put_payload(
    "books",
    Map([("pk", Text("book#1"))]),
    condition_expression=Some("attribute_not_exists(pk)"),
    expression_attribute_values=Map([]),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"Item\":{\"pk\":{\"S\":\"book#1\"}},\"ConditionExpression\":\"attribute_not_exists(pk)\"}",
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
    exclusive_start_key=Some(Map([("pk", Text("book#0"))])),
    limit=Some(10),
  )
  assert_eq(
    payload.stringify(),
    "{\"TableName\":\"books\",\"KeyConditionExpression\":\"pk = :pk\",\"ExpressionAttributeValues\":{\":pk\":{\"S\":\"book#1\"}},\"ExclusiveStartKey\":{\"pk\":{\"S\":\"book#0\"}},\"Limit\":10}",
  )
}

///|
test "missing item response means no match" {
  assert_eq(parse_get_item(@json.parse("{}")), None)
}
