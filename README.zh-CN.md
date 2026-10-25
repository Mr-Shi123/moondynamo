# MoonDynamo

[English](README.md) | 简体中文

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

一个类型化的 Amazon DynamoDB 客户端，用 MoonBit 编写。MoonDynamo 直接使用 DynamoDB JSON API，并用 AWS Signature Version 4 签名每一个请求，因此既可以对接真实的 AWS 端点，也可以对接 [DynamoDB Local](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html)——适合在 MoonBit 应用中使用，也适合做本地集成测试。

## 功能特性

- **核心操作**：`CreateTable`、`DescribeTable`、`PutItem`、`GetItem`、`DeleteItem` 和 `Query`。
- **完整的 DynamoDB 属性类型**：`S`、`N`、`B`、`BOOL`、`NULL`、`L`、`M`、`SS`、`NS`、`BS` 全部映射到一个类型化的 `AttributeValue` 枚举。数字始终以十进制字符串表示，全程不经过浮点数，不会有精度损失。
- **条件写入与查询**：条件表达式和键表达式由你编写，客户端负责携带类型化的表达式占位值。
- **分页**：`Query` 返回 `LastEvaluatedKey`；把它作为 `exclusive_start_key` 传回，即可逐页遍历表数据。
- **结构化错误**：服务端错误抛出 `DynamoError::Service`，携带 HTTP 状态码、错误代码、错误消息以及本次请求的 `x-amzn-RequestId`。
- **本地优先的配置**：服务地址、区域、凭证（含会话令牌）全部显式传入，连接 DynamoDB Local 无需额外设置。

## 环境要求

- 较新的 [moon](https://docs.moonbitlang.com) 构建——已在 `0.1.20260920` 上验证。MoonDynamo 以 **JavaScript** 为目标后端，运行于 Node.js。
- 可选：Java 8+ 用于运行 DynamoDB Local，或 Node.js 18+ 用于项目自带的 mock 服务。

## 安装

在你的项目根目录执行：

```bash
moon add Mr-Shi123/moondynamo
```

然后在使用它的包的 `moon.pkg` 中导入：

```json
import {
  "Mr-Shi123/moondynamo"
}
```

导入后即可通过默认别名 `@moondynamo` 使用。

## 快速开始

在本仓库根目录运行测试与严格检查：

```bash
moon test --target js
moon check --target js --deny-warn
```

项目自带的端到端示例（[cmd/main/main.mbt](cmd/main/main.mbt)）会建表、写入一本书、读取、按键查询、删除并确认记录已消失。表会保留，方便重复运行。

**方式一 —— DynamoDB Local**（推荐）：

```bash
docker run --rm -p 8000:8000 amazon/dynamodb-local
# 在另一个终端
moon run cmd/main --target js
```

**方式二 —— 自带 mock 服务**：一个零依赖的测试服务（[scripts/mock-dynamodb.mjs](scripts/mock-dynamodb.mjs)），无需 Docker 即可监听 `127.0.0.1:8000`。它会检查每个请求的内容类型、操作与请求体，并在响应前**独立重算每一次 SigV4 签名**；当预定的七步场景全部通过后自动退出：

```bash
node scripts/mock-dynamodb.mjs
# 在另一个终端
moon run cmd/main --target js
```

两种方式成功时都会输出 `MoonDynamo local example passed`。

## 使用示例

以下示例假设服务运行在 `127.0.0.1:8000`（DynamoDB Local 或 mock），并使用仅供本地测试的假凭证——切勿在源码中内嵌真实凭证。所有调用都是 `async`，因此这些片段位于 `async fn main` 内部。

### 构造客户端

```moonbit
let config : @moondynamo.Config = {
  endpoint: "http://127.0.0.1:8000",
  region: "us-east-1",
  credentials: {
    access_key_id: "local",
    secret_access_key: "local",
    session_token: None,
  },
}
let db = @moondynamo.Client::new(config)
```

`endpoint` 必须是不带路径的 `http://` 或 `https://` origin（ASCII 域名或 IPv4 地址）；客户端会在签名前规范化主机名大小写并去掉默认端口。AWS 临时凭证放入 `session_token`。

### 建表

```moonbit
try db.create_table("Books", "pk") |> ignore catch {
  @moondynamo.DynamoError::Service(_, "ResourceInUseException", _, _) => ()
  error => raise error
}
db.describe_table("Books") |> ignore
```

`create_table` 创建按需计费（pay-per-request）的表，使用字符串分区键，并可通过 `sort_key?` 指定可选的字符串排序键。捕获 `ResourceInUseException` 可以让重复执行保持幂等。

### 写入与读取

```moonbit
let item : @moondynamo.Item = Map([
  ("pk", @moondynamo.Text("book#1")),
  ("title", @moondynamo.Text("The MoonBit Book")),
  ("pages", @moondynamo.Number("128")),
  ("tags", @moondynamo.StringSet(["moonbit", "database"])),
])
db.put_item("Books", item)

let saved = db.get_item(
  "Books",
  Map([("pk", @moondynamo.Text("book#1"))]),
  consistent_read=true,
)
guard saved is Some(book) else { fail("GetItem returned no item") }
guard book.get("title") == Some(@moondynamo.Text("The MoonBit Book")) else {
  fail("GetItem returned an unexpected item")
}
```

键不存在时 `get_item` 返回 `None`。

### 条件写入

```moonbit
try db.put_item(
  "Books",
  item,
  condition_expression="attribute_not_exists(pk)",
) catch {
  @moondynamo.DynamoError::Service(
    _,
    "ConditionalCheckFailedException",
    message,
    _,
  ) => println("conditional write rejected: \{message}")
  error => raise error
}
```

表达式字符串由你编写；类型化的占位值通过 `expression_attribute_values?` 传入——例如 `Map([(":max", @moondynamo.Number("500"))])`。

### 查询与分页

```moonbit
let mut exclusive_start_key : @moondynamo.Item? = None
let mut pages = 0
while true {
  let page = db.query(
    "Books",
    "pk = :pk",
    Map([(":pk", @moondynamo.Text("book#1"))]),
    exclusive_start_key?,
    limit=1,
  )
  pages = pages + page.items.length()
  match page.last_evaluated_key {
    Some(key) => exclusive_start_key = Some(key)
    None => break
  }
}
println("query matched \{pages} item(s)")
```

这里把 `limit` 设得很小，只是为了在小表上强制触发 `LastEvaluatedKey` 续页；实际使用中去掉即可拿到整页数据。持续调用直到 `last_evaluated_key` 为 `None`。

### 错误处理

每个操作都可能抛错；按需捕获并检查：

```moonbit
try db.describe_table("Books") |> ignore catch {
  @moondynamo.DynamoError::Service(status, code, message, request_id) =>
    println("HTTP \{status} \{code}: \{message} (request \{request_id})")
  error => raise error
}
```

## 属性值类型

`Item` 是 `Map[String, AttributeValue]` 的别名。完整的线格式覆盖：

| MoonBit | DynamoDB JSON | 说明 |
| --- | --- | --- |
| `Text("hi")` | `{"S": "hi"}` | UTF-8 字符串 |
| `Number("128")` | `{"N": "128"}` | 十进制文本——无浮点舍入 |
| `Binary(b)` | `{"B": "<base64>"}` | `Bytes`，base64 编码 |
| `BoolValue(true)` | `{"BOOL": true}` | |
| `NullValue` | `{"NULL": true}` | |
| `ListValue([...])` | `{"L": [...]}` | 嵌套值 |
| `ObjectValue({...})` | `{"M": {...}}` | 嵌套文档 |
| `StringSet(["a"])` | `{"SS": ["a"]}` | |
| `NumberSet(["1"])` | `{"NS": ["1"]}` | 十进制文本 |
| `BinarySet([b])` | `{"BS": ["<base64>"]}` | |

`AttributeValue` 派生了 `Eq`，方便在测试中对结果做断言。

## 错误模型

```moonbit
pub(all) suberror DynamoError {
  InvalidConfig(String)
  InvalidResponse(String)
  Service(Int, String, String, String?)
}
```

- `InvalidConfig`——端点不合法、区域或凭证为空、时间戳格式错误。
- `InvalidResponse`——2xx 响应但客户端无法解析。
- `Service(status, code, message, request_id)`——非 2xx 响应。错误代码取自 `__type` 的后缀（或 `code` 字段），例如 `ConditionalCheckFailedException`；消息从 `message` 回退到 `Message`；请求 ID 来自 `x-amzn-RequestId` 响应头。即使错误响应体不是 JSON，也会以 `Service` 和错误代码 `UnknownServiceError` 抛出——调用者总能拿到类型化的错误。

## 测试与验证

- **16 个单元测试**（`moon test --target js`）覆盖属性值往返转换、请求构造与签名、响应与错误解析、分页请求负载。
- **自带验证的 HTTP fixture**（[scripts/mock-dynamodb.mjs](scripts/mock-dynamodb.mjs)）走真实 HTTP 往返，并独立重算每一次 SigV4 签名——签名实现一旦漂移，测试会立即失败。
- **已对 DynamoDB Local 1.25.1 做真机端到端验证**：`CreateTable → DescribeTable → PutItem → GetItem → Query → DeleteItem → GetItem`，包括用真实的 `ConditionalCheckFailedException` 验证条件写入拒绝，以及通过 `LastEvaluatedKey` 完成多页 `Query` 遍历。

### 平台状态

- **JavaScript**——编译、单元测试与真实 HTTP 调用均已验证。
- **原生目标**——`moon check` 通过。在 Windows 上原生运行目前受限于 `moonbitlang/async` 的 C 源码与 MinGW 不兼容（该依赖的 Windows 事件循环要求 MSVC）；原生运行时验证尚未完成。

## 架构

两个很薄的层次：

- **协议层**（`protocol.mbt`、`attribute.mbt`）——无 I/O 的纯函数：规范化端点、构造 DynamoDB JSON 负载、用 [`kaashyapan/sigv4`](https://mooncakes.io/docs/kaashyapan/sigv4) 签名、把响应解析为类型化的值或结构化错误。纯函数让整个线格式可以确定性地测试。
- **客户端层**（`client.mbt`）——一个很小的 async 封装，通过 [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async) 的 HTTP 客户端发送请求。

## 当前边界

- 凭证由调用方传入——没有默认凭证搜索链，也没有自动刷新。
- 端点必须是不带路径的 origin；暂不支持 IPv6 主机名。
- 支持值占位符（`:name`）；暂不支持名称占位符（`#name`）和表达式生成器。
- 暂无 Batch*、Transact*、`Scan`、Streams、PartiQL 或自动建模。
- `create_table` 只能创建字符串键的按需计费表；其他表结构暂需更底层的调用。

## 许可证

[Apache-2.0](LICENSE)。依赖——[moonbitlang/async](https://mooncakes.io/docs/moonbitlang/async)、[moonbitlang/x](https://mooncakes.io/docs/moonbitlang/x)、[kaashyapan/sigv4](https://mooncakes.io/docs/kaashyapan/sigv4)——同样均为 Apache-2.0。
