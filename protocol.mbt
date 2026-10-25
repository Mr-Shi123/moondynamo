///|
/// AWS credentials supplied by the caller. Temporary credentials include a
/// session token; the client signs that token with every request.
pub(all) struct Credentials {
  access_key_id : String
  secret_access_key : String
  session_token : String?
}

///|
/// `endpoint` is an origin without a trailing slash, using an ASCII DNS name
/// or IPv4 address, for example `https://dynamodb.us-east-1.amazonaws.com`
/// or `http://127.0.0.1:8000`.
pub(all) struct Config {
  endpoint : String
  region : String
  credentials : Credentials
}

///|
pub(all) struct PreparedRequest {
  url : String
  headers : Map[String, String]
  body : String
}

///|
pub(all) suberror DynamoError {
  InvalidConfig(String)
  InvalidResponse(String)
  Service(Int, String, String, String?)
}

///|
fn endpoint_origin(endpoint : String) -> (String, String) raise DynamoError {
  let (scheme, authority) = if endpoint.has_prefix("https://") {
    ("https://", endpoint[8:].to_owned())
  } else if endpoint.has_prefix("http://") {
    ("http://", endpoint[7:].to_owned())
  } else {
    raise InvalidConfig("endpoint must start with http:// or https://")
  }
  if authority.is_empty() ||
    authority.contains("/") ||
    authority.contains("?") ||
    authority.contains("#") {
    raise InvalidConfig("endpoint must be an origin without path or query")
  }
  let (hostname, raw_port) = match authority.split_once(":") {
    Some((name, port)) => (name.to_owned(), Some(port.to_owned()))
    None => (authority, None)
  }
  if hostname.is_empty() {
    raise InvalidConfig("endpoint host must not be empty")
  }
  for ch in hostname.to_array() {
    if !((ch >= 'A' && ch <= 'Z') ||
      (ch >= 'a' && ch <= 'z') ||
      (ch >= '0' && ch <= '9') ||
      ch == '.' ||
      ch == '-') {
      raise InvalidConfig("endpoint must use an ASCII DNS name or IPv4 address")
    }
  }
  let port = match raw_port {
    Some(value) => {
      let number = @string.parse_int(value) catch {
        _ => raise InvalidConfig("endpoint port must be numeric")
      }
      if number < 1 || number > 65535 {
        raise InvalidConfig("endpoint port must be between 1 and 65535")
      }
      if (scheme == "http://" && number == 80) ||
        (scheme == "https://" && number == 443) {
        None
      } else {
        Some(number)
      }
    }
    None => None
  }
  let host = hostname.to_lower()
  let canonical_authority = match port {
    Some(number) => host + ":" + number.to_string()
    None => host
  }
  (scheme, canonical_authority)
}

///|
/// Prepare a signed DynamoDB JSON request with a caller-supplied UTC
/// timestamp (`YYYYMMDDTHHMMSSZ`). Supplying the time keeps this layer pure.
pub fn prepare_request(
  config : Config,
  action : String,
  payload : Json,
  timestamp : String,
) -> PreparedRequest raise DynamoError {
  let (scheme, host) = endpoint_origin(config.endpoint)
  if config.region.is_empty() ||
    config.credentials.access_key_id.is_empty() ||
    config.credentials.secret_access_key.is_empty() {
    raise InvalidConfig("region and credentials must be present")
  }
  if timestamp.length() != 16 || !timestamp.has_suffix("Z") {
    raise InvalidConfig("timestamp must have form YYYYMMDDTHHMMSSZ")
  }
  if action.is_empty() || action.contains("\n") || action.contains("\r") {
    raise InvalidConfig("invalid DynamoDB action")
  }
  let body = payload.stringify()
  let credentials : @sigv4.Credentials = {
    access_key_id: config.credentials.access_key_id,
    secret_access_key: config.credentials.secret_access_key,
    session_token: config.credentials.session_token,
  }
  let signed = @sigv4.sign(
    {
      meth: @http.Post,
      path: "/",
      query: [],
      headers: [
        ("Host", host),
        ("Content-Type", "application/x-amz-json-1.0"),
        ("X-Amz-Target", "DynamoDB_20120810.\{action}"),
      ],
      body: @utf8.encode(body),
    },
    credentials,
    @sigv4.SigningOptions(timestamp~, region=config.region, service="dynamodb"),
  )
  let headers : Map[String, String] = Map([])
  for (name, value) in signed.headers {
    headers[name] = value
  }
  { url: scheme + host + "/", headers, body, }
}

///|
fn json_field(fields : Map[String, Json], name : String) -> String? {
  match fields.get(name) {
    Some(String(text)) => Some(text)
    _ => None
  }
}

///|
fn request_id(headers : Map[String, String]) -> String? {
  for name, value in headers {
    if name.to_lower() == "x-amzn-requestid" {
      return Some(value)
    }
  }
  None
}

///|
/// Decode a DynamoDB response. Non-2xx responses become typed service
/// errors, preserving the service code and request ID for callers.
pub fn parse_response(
  status : Int,
  headers : Map[String, String],
  body : String,
) -> Json raise DynamoError {
  let parsed = @json.parse(body) catch {
    _ => {
      if status >= 200 && status < 300 {
        raise InvalidResponse("DynamoDB returned invalid JSON (HTTP \{status})")
      }
      raise Service(
        status,
        "UnknownServiceError",
        "DynamoDB returned a non-JSON error response",
        request_id(headers),
      )
    }
  }
  let fields = match parsed {
    Object(fields) => fields
    _ => {
      if status >= 200 && status < 300 {
        raise InvalidResponse("DynamoDB response must be a JSON object")
      }
      raise Service(
        status,
        "UnknownServiceError",
        "DynamoDB returned a non-object error response",
        request_id(headers),
      )
    }
  }
  if status >= 200 && status < 300 {
    return parsed
  }
  let raw_code = match json_field(fields, "__type") {
    Some(value) => value
    None =>
      match json_field(fields, "code") {
        Some(value) => value
        None => "UnknownServiceError"
      }
  }
  let code = match raw_code.split_once("#") {
    Some((_, suffix)) => suffix.to_owned()
    None => raw_code
  }
  let message = match json_field(fields, "message") {
    Some(value) => value
    None =>
      match json_field(fields, "Message") {
        Some(value) => value
        None => "DynamoDB request failed"
      }
  }
  raise Service(status, code, message, request_id(headers))
}
