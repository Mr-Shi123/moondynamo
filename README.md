# MoonDynamo

MoonDynamo 是一个用 MoonBit 编写的 DynamoDB 客户端。它直接使用 DynamoDB JSON API，通过 AWS Signature Version 4 签名请求，适合在 MoonBit 应用或本地集成测试中读写 DynamoDB。

当前版本提供：

- `CreateTable`、`DescribeTable`、`PutItem`、`GetItem`、`DeleteItem`、`Query`。
- 完整的 DynamoDB 属性类型：`S`、`N`、`B`、`BOOL`、`NULL`、`L`、`M`、`SS`、`NS`、`BS`。数字保留为十进制字符串，避免浮点精度损失。
- 条件写入表达式、查询键表达式、表达式占位值，以及 `Query` 的 `LastEvaluatedKey` 分页标记。
- 可配置区域、服务地址和 AWS 临时凭证；服务错误保留 HTTP 状态、错误代码、消息及请求 ID。

## 快速开始

在项目根目录执行：

```powershell
moon test --target js
moon check --target js --deny-warn
```

本地示例位于 [`cmd/main/main.mbt`](cmd/main/main.mbt)，使用 `http://127.0.0.1:8000` 和仅供本地使用的假凭证。可以用 [DynamoDB Local](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html) 启动服务，例如：

```powershell
docker run --rm -p 8000:8000 amazon/dynamodb-local
```

然后在另一个终端运行：

```powershell
moon run cmd/main --target js
```

示例会建表（表已存在时继续）、写入一本书、读取、按键查询、删除并确认记录已消失。表会保留，以便重复运行。`CreateTable` 目前只创建按需计费、字符串类型分区键及可选排序键的表。

没有 DynamoDB Local 时，也可以运行项目自带的 HTTP 测试服务：

```powershell
node scripts/mock-dynamodb.mjs
```

再在另一个终端运行同一条 `moon run cmd/main --target js` 命令。这个测试服务会检查请求内容，并独立计算每次请求的 SigV4 签名。

## 在代码中使用

向 MoonBit 包的 `moon.pkg` 导入 `Mr-Shi123/moondynamo`，构造 `Config` 和 `Client`。下面是本地服务的最小例子；连接 AWS 时将 `endpoint` 换成所在区域的 DynamoDB 地址，并从自己的安全配置中提供凭证：

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
let item : @moondynamo.Item = Map([
  ("pk", @moondynamo.Text("book#1")),
  ("pages", @moondynamo.Number("128")),
])
db.put_item("Books", item)
```

`query` 接收 `exclusive_start_key?` 和 `limit?`。如果返回的 `QueryResult.last_evaluated_key` 是 `Some(key)`，将它作为下一次查询的 `exclusive_start_key`，直到结果为 `None`。操作可能抛出 `DynamoError::Service(status, code, message, request_id)`；例如条件失败时的 `code` 是 `ConditionalCheckFailedException`。

## 当前边界

- 凭证由调用方传入；没有默认凭证搜索链或自动刷新。
- 服务地址应为不带路径的 `http://` 或 `https://` origin，主机名使用 ASCII DNS 名称或 IPv4 地址；客户端会规范化大小写及默认端口后签名。
- 查询和条件表达式由调用方编写；目前支持属性值占位符，尚无属性名占位符或表达式生成器。
- 暂无批量、事务、扫描、Streams、PartiQL 或自动建模功能。
- 已验证 JavaScript 目标的编译、单元测试和本地 HTTP 调用链。原生目标通过 `moon check`，但这台 Windows 机器上的 MinGW 与 `moonbitlang/async` 原生 C 依赖不兼容，无法在此环境完成原生运行测试。

依赖版本和构建配置见 [`moon.mod`](moon.mod)。项目采用 Apache-2.0 许可证。
