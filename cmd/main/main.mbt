///|
/// A small end-to-end example for DynamoDB Local at 127.0.0.1:8000.
async fn main {
  let config : @lib.Config = {
    endpoint: "http://127.0.0.1:8000",
    region: "us-east-1",
    credentials: {
      access_key_id: "local",
      secret_access_key: "local",
      session_token: None,
    },
  }
  let db = @lib.Client::new(config)
  try db.create_table("MoonDynamoExample", "pk") |> ignore catch {
    @lib.DynamoError::Service(_, "ResourceInUseException", _, _) => ()
    error => raise error
  }
  db.describe_table("MoonDynamoExample") |> ignore
  let tables = db.list_tables(limit=1)
  guard !tables.table_names.is_empty() else {
    fail("ListTables returned no tables")
  }
  // "status" collides with a DynamoDB reserved word in expressions, so the
  // query below reaches it through a #name placeholder.
  let item : @lib.Item = Map([
    ("pk", @lib.Text("book#1")),
    ("title", @lib.Text("The MoonBit Book")),
    ("pages", @lib.Number("128")),
    ("status", @lib.Text("active")),
  ])
  db.put_item("MoonDynamoExample", item)
  let key : @lib.Item = Map([("pk", @lib.Text("book#1"))])
  let found = db.get_item("MoonDynamoExample", key)
  guard found is Some(found_item) else { fail("GetItem returned no item") }
  guard found_item.get("title") == Some(@lib.Text("The MoonBit Book")) else {
    fail("GetItem returned an unexpected item")
  }
  let updated = db.update_item(
    "MoonDynamoExample",
    key,
    "SET pages = :pages",
    expression_attribute_values=Map([(":pages", @lib.Number("200"))]),
    return_values=AllNew,
  )
  guard updated is Some(book) && book.get("pages") == Some(@lib.Number("200")) else {
    fail("UpdateItem did not apply the new page count")
  }
  let result = db.query(
    "MoonDynamoExample",
    "pk = :pk",
    Map([(":pk", @lib.Text("book#1")), (":st", @lib.Text("active"))]),
    filter_expression="#st = :st",
    expression_attribute_names=Map([("#st", "status")]),
  )
  guard result.items.length() == 1 else { fail("Query returned no item") }
  let scanned = db.scan("MoonDynamoExample")
  guard scanned.items.length() == 1 else { fail("Scan returned no item") }
  db.delete_item("MoonDynamoExample", key)
  guard db.get_item("MoonDynamoExample", key) is None else {
    fail("DeleteItem did not remove the item")
  }
  println("MoonDynamo local example passed")
}
