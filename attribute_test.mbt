///|
test "number attribute keeps all decimal digits" {
  let value : @moondynamo.AttributeValue = Number(
    "12345678901234567890.123456789",
  )
  let encoded = @moondynamo.encode_attribute(value)
  assert_eq(encoded.stringify(), "{\"N\":\"12345678901234567890.123456789\"}")
  let decoded = @moondynamo.decode_attribute(encoded)
  assert_eq(decoded, value)
}

///|
test "nested item values round trip through DynamoDB JSON" {
  let item : @moondynamo.Item = Map([
    ("pk", Text("user#1")),
    ("active", BoolValue(true)),
    ("tags", StringSet(["moon", "db"])),
    (
      "meta",
      ObjectValue(
        Map([
          ("rank", Number("9007199254740993")),
          ("notes", ListValue([Text("hello"), NullValue])),
        ]),
      ),
    ),
  ])
  let encoded = @moondynamo.encode_item(item)
  assert_eq(@moondynamo.decode_item(encoded), item)
}

///|
test "binary attributes are base64 on the wire" {
  let value : @moondynamo.AttributeValue = Binary(b"\x00\xFF")
  assert_eq(@moondynamo.encode_attribute(value).stringify(), "{\"B\":\"AP8=\"}")
  assert_eq(
    @moondynamo.decode_attribute(@json.parse("{\"B\":\"AP8=\"}")),
    value,
  )
}

///|
test "number and binary sets round trip without changing their values" {
  let item : @moondynamo.Item = Map([
    ("numbers", NumberSet(["9007199254740993", "-1.25"])),
    ("blobs", BinarySet([b"\x00\xFF", b"moon"])),
    ("disabled", BoolValue(false)),
  ])
  assert_eq(@moondynamo.decode_item(@moondynamo.encode_item(item)), item)
}

///|
test "malformed binary attribute fails clearly" {
  try
    @moondynamo.decode_attribute(@json.parse("{\"B\":\"%%%\"}")) |> ignore
  catch {
    @moondynamo.CodecError::InvalidAttribute(_) => ()
    _ => fail("unexpected error kind")
  } noraise {
    _ => fail("invalid base64 must fail")
  }
}

///|
test "invalid attribute tag is rejected" {
  let bad = @json.parse("{\"UNKNOWN\":\"x\"}")
  try @moondynamo.decode_attribute(bad) |> ignore catch {
    @moondynamo.CodecError::InvalidAttribute(_) => ()
  } noraise {
    _ => fail("unknown attribute tag must fail")
  }
}
