import http from 'node:http';
import crypto from 'node:crypto';

const table = 'MoonDynamoExample';
let created = false;
let item = null;
const actions = [];

const sha256 = value => crypto.createHash('sha256').update(value).digest('hex');
const hmac = (key, value) => crypto.createHmac('sha256', key).update(value).digest();

const verifySignature = (request, body) => {
  const authorization = request.headers.authorization;
  const match = authorization?.match(/^AWS4-HMAC-SHA256 Credential=([^,]+), SignedHeaders=([^,]+), Signature=([a-f0-9]{64})$/);
  if (!match) throw new Error('invalid SigV4 authorization');
  const [, credential, signedHeaders, signature] = match;
  const [accessKey, date, region, service, terminator] = credential.split('/');
  if (accessKey !== 'local' || region !== 'us-east-1' || service !== 'dynamodb' || terminator !== 'aws4_request') {
    throw new Error('incorrect SigV4 credential scope');
  }
  const timestamp = request.headers['x-amz-date'];
  if (!timestamp?.startsWith(date)) throw new Error('incorrect SigV4 timestamp');
  const canonicalHeaders = signedHeaders.split(';').map(name => {
    const value = request.headers[name];
    if (typeof value !== 'string') throw new Error(`missing signed header ${name}`);
    return `${name}:${value.trim().replace(/\s+/g, ' ')}\n`;
  }).join('');
  const canonicalRequest = `POST\n/\n\n${canonicalHeaders}\n${signedHeaders}\n${sha256(body)}`;
  const scope = `${date}/${region}/${service}/aws4_request`;
  const stringToSign = `AWS4-HMAC-SHA256\n${timestamp}\n${scope}\n${sha256(canonicalRequest)}`;
  const signingKey = hmac(hmac(hmac(hmac(`AWS4local`, date), region), service), 'aws4_request');
  const expected = crypto.createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  if (signature !== expected) throw new Error('SigV4 signature did not match request');
};

const send = (response, status, value) => {
  response.writeHead(status, {
    'content-type': 'application/x-amz-json-1.0',
    'x-amzn-requestid': `local-${actions.length}`,
  });
  response.end(JSON.stringify(value));
};

const server = http.createServer(async (request, response) => {
  try {
    if (request.method !== 'POST' || request.url !== '/') {
      throw new Error('expected a POST to /');
    }
    if (request.headers['content-type'] !== 'application/x-amz-json-1.0') {
      throw new Error('incorrect DynamoDB content type');
    }
    const target = request.headers['x-amz-target'];
    const action = target?.replace('DynamoDB_20120810.', '');
    let data = '';
    for await (const chunk of request) data += chunk;
    verifySignature(request, data);
    const body = JSON.parse(data);
    actions.push(action);
    if (body.TableName !== table) throw new Error('unexpected table');
    switch (action) {
      case 'CreateTable':
        if (body.BillingMode !== 'PAY_PER_REQUEST' || body.KeySchema?.[0]?.AttributeName !== 'pk') {
          throw new Error('invalid table schema');
        }
        created = true;
        send(response, 200, { TableDescription: { TableName: table, TableStatus: 'ACTIVE' } });
        break;
      case 'DescribeTable':
        if (!created) throw new Error('table has not been created');
        send(response, 200, { Table: { TableName: table, TableStatus: 'ACTIVE' } });
        break;
      case 'PutItem':
        if (!created || body.Item?.pk?.S !== 'book#1' || body.Item?.pages?.N !== '128') {
          throw new Error('invalid PutItem');
        }
        item = body.Item;
        send(response, 200, {});
        break;
      case 'GetItem':
        if (body.Key?.pk?.S !== 'book#1') throw new Error('invalid GetItem key');
        send(response, 200, item ? { Item: item } : {});
        break;
      case 'UpdateItem':
        if (body.Key?.pk?.S !== 'book#1') throw new Error('invalid UpdateItem key');
        if (body.UpdateExpression !== 'SET pages = :pages' || body.ExpressionAttributeValues?.[':pages']?.N !== '200') {
          throw new Error('invalid UpdateItem expression');
        }
        if (body.ReturnValues !== 'ALL_NEW') throw new Error('unexpected UpdateItem ReturnValues');
        item = { ...item, pages: { N: '200' } };
        send(response, 200, { Attributes: item });
        break;
      case 'Query':
        if (body.KeyConditionExpression !== 'pk = :pk' || body.ExpressionAttributeValues?.[':pk']?.S !== 'book#1') {
          throw new Error('invalid Query expression');
        }
        if (body.FilterExpression !== '#st = :st' || body.ExpressionAttributeNames?.['#st'] !== 'status' || body.ExpressionAttributeValues?.[':st']?.S !== 'active') {
          throw new Error('invalid Query filter');
        }
        send(response, 200, { Items: item ? [item] : [], Count: item ? 1 : 0, ScannedCount: item ? 1 : 0 });
        break;
      case 'Scan':
        if (Object.keys(body).length !== 1) throw new Error('invalid Scan request');
        send(response, 200, { Items: item ? [item] : [], Count: item ? 1 : 0, ScannedCount: item ? 1 : 0 });
        break;
      case 'DeleteItem':
        if (body.Key?.pk?.S !== 'book#1') throw new Error('invalid DeleteItem key');
        item = null;
        send(response, 200, {});
        break;
      default:
        throw new Error(`unexpected action ${action}`);
    }
    if (actions.join(',') === 'CreateTable,DescribeTable,PutItem,GetItem,UpdateItem,Query,Scan,DeleteItem,GetItem') {
      console.log('HTTP integration fixture passed: ' + actions.join(' → '));
      server.close();
    }
  } catch (error) {
    console.error(error);
    send(response, 500, { __type: 'FixtureError', message: String(error) });
    server.close();
    process.exitCode = 1;
  }
});

server.listen(8000, '127.0.0.1', () => console.log('Fixture listening on 127.0.0.1:8000'));
