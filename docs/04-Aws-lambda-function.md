# AWS Lambda Concurrency & Invocations Lab

Lab này minh họa:

  - Khái niệm cơ bản về AWS Lambda (invocations, concurrency, retry, DLQ,…).
  - Synchronous Lambda (API Gateway → Lambda).
  - Asynchronous Lambda (S3 → Lambda → SQS DLQ).
  - Reserved Concurrency và Provisioned Concurrency.
  - Cách suy nghĩ về SQS → Lambda concurrency.

## 0. Tổng quan lý thuyết AWS Lambda

### 0.1. AWS Lambda là gì?

- Dịch vụ serverless compute của AWS:
  - Chạy code mà không cần quản lý server.
  - Tự động scale theo số lượng request (concurrency).
- Hỗ trợ nhiều runtime: Node.js, Python, Java, Go, .NET, v.v.
- Tính phí theo:
  - Số lần gọi (invocations).
  - Thời gian chạy (duration) × bộ nhớ (memory).
    
### 0.2. Invocation (Cách Lambda được gọi)

3 kiểu chính:

1. Synchronous (đồng bộ)  

    - Caller chờ Lambda chạy xong, nhận kết quả.
    - Ví dụ: API Gateway, AWS SDK gọi trực tiếp.
    - Nếu Lambda lỗi → caller nhận lỗi ngay.

2. Asynchronous (bất đồng bộ)  

    - Caller gửi event, không chờ kết quả.
    - Ví dụ: S3, SNS, EventBridge.
    - Lambda tự retry (theo config) và có thể gửi event thất bại vào DLQ / Event Destination.
    
3. Event Source Mapping (stream/poll-based)  

    - Lambda chủ động poll dữ liệu từ nguồn:
      - SQS, Kinesis, DynamoDB Streams, Kafka…
    - Mỗi batch data đọc được → 1 lần invoke Lambd

### 0.3. Concurrency (Đồng thời)

  - Concurrency = số invocation đang chạy cùng lúc cho 1 function.
  - Khi có nhiều request/event, Lambda sẽ tạo thêm instance để xử lý song song.
    
Các loại concurrency:

  1. Unreserved Account Concurrency

    - Tổng concurrency cho toàn account trong 1 region.
    - Tất cả function dùng chung (trừ phần đã “reserved”).
  
  2. Reserved Concurrency (per function)

    - Thuộc tính reserved_concurrent_executions trên từng function.
    - Ý nghĩa:
      - Giới hạn tối đa concurrent executions của function đó.
      - Đồng thời dành riêng bấy nhiêu slot cho function (hàm khác không xài được).
    
  3. Provisioned Concurrency

    - Giữ sẵn N instance “ấm” (warm) cho 1 version/alias cụ thể.
    - Giảm mạnh cold start, phù hợp với API latency thấp / microservices.
    - Cấu hình qua aws_lambda_provisioned_concurrency_config, gắn với alias/version (không áp dụng được cho $LATEST chưa publish).

### 0.4. Throttle & Retry

- Throttle (Rate Exceeded / TooManyRequests):

  - Xảy ra khi:
    - Vượt account concurrency limit.
    - Vượt reserved_concurrent_executions của function.
  - Synchronous:
    - Caller nhận lỗi ngay (thường HTTP 429/500 tuỳ mapping).
  - Asynchronous:
    - Lambda retry với backoff; nếu vẫn không được → đẩy vào DLQ / Event Destination (nếu cấu hình).
      
- Retry behavior:

  - Sync: không có auto retry phía Lambda. Retry là trách nhiệm của client / ứng dụng.
  - Async (S3, SNS, EventBridge):
    - Retry tự động, số lần theo maximum_retry_attempts (khi cấu hình function_event_invoke_config).
  - SQS / Streams (event source mapping):
    - Lambda đọc lại message đến khi thành công hoặc message được chuyển sang DLQ của SQS theo policy.

### 0.5. Dead Letter Queue (DLQ) & Event Destinations

- DLQ (Dead Letter Queue):

  - Thường là SQS hoặc SNS.
  - Lưu các event mà Lambda xử lý thất bại sau khi đã retry.
  - Dùng để:
    - Debug, kiểm tra lỗi.
    - Hoặc có 1 worker khác đọc & xử lý lại.
      
- Event Destinations (cho async invoke):

  - Cấu hình điểm đến cho:
    - on_failure: khi Lambda lỗi sau retry.
    - on_success: khi Lambda xử lý thành công.
  - Destination có thể là: SQS, SNS, Lambda khác, EventBridge.


### 0.6. Monitoring & Observability cho Lambda

Monitoring giúp bạn hiểu:

  - Lambda đang chạy tốt hay không?
  - Concurrency có bị full không?
  - Có bị throttle, lỗi nhiều không?
  - Thời gian chạy (duration) và lỗi (error) như thế nào?
    
AWS cung cấp các công cụ chính:

  - CloudWatch Logs – log chi tiết từng invoke.
  - CloudWatch Metrics – metric tổng quan (Invocations, Errors, Duration,…).
  - X-Ray – trace, profiling chi tiết (tuỳ chọn).
    
#### 0.6.1. CloudWatch Logs

Mỗi Lambda function mặc định log vào CloudWatch Logs (nhờ policy AWSLambdaBasicExecutionRole):

  - Log group: /aws/lambda/<function_name>.
  - Mỗi container/instance có log stream riêng.

Dùng CLI:

```bash
aws logs tail "/aws/lambda/sync-api-lambda" --since 5m

```

Trong log bạn thường thấy:

  - START RequestId: ...
  - Log của bạn: console.log(...), console.error(...).
  - END RequestId: ...
  - REPORT RequestId: ... Duration: ... ms ...


#### 0.6.2. CloudWatch Metrics – Những metric quan trọng

Vào CloudWatch → Metrics → Lambda → chọn theo FunctionName.

Các metric chính:

  - Invocations  

    - Số lần function được invoke (kể cả thành công hay lỗi).
      
  - Errors  

    - Số lần invoke trả lỗi (không tính retry async nội bộ).
      
  - Throttles  

    - Số lần bị throttle (Rate Exceeded / TooManyRequests) do:
      - Vượt account concurrency.
      - Vượt reserved_concurrent_executions.

  - ConcurrentExecutions  

    - Số instance đang chạy cùng lúc cho function.
      
  - Duration  

    - Thời gian chạy (ms).
    - Có thể xem P50, P90, P95,… để hiểu latency.
      
  - ProvisionedConcurrentExecutions / ProvisionedConcurrencyUtilization (nếu dùng PC)  

    - Theo dõi mức độ sử dụng Provisioned Concurrency.
      
Bạn có thể dùng các metric này để:

  - Vẽ biểu đồ concurrency theo thời gian.
  - Phát hiện khi nào function bị throttle.
  - Tối ưu memory / timeout / provisioned concurrency.


#### 0.6.3 Lý thuyết: SQS → Lambda & xử lý đồng thời nhiều message

##### 1. SQS → Lambda hoạt động thế nào?

Bạn cấu hình Event Source Mapping giữa SQS và Lambda:
```text
[Producer] -> [SQS Queue] -> [Event Source Mapping] -> [Lambda Function]

```
- Event Source Mapping sẽ:
  - Poll message từ SQS.
  - Gom message theo batch_size.
  - Mỗi batch → 1 lần invoke Lambda (1 execution).

##### 2. batch_size và Records

- batch_size = N → mỗi execution Lambda nhận tối đa N message:
```json
{
  "Records": [
    { "body": "msg1", ... },
    { "body": "msg2", ... },
    ...
    { "body": "msgN", ... }
  ]
}

```

- Thường trong handler:
```js
for (const record of event.Records) {
  // xử lý từng message trong batch
}

```

##### 3. Xử lý đồng thời nhiều message

- Concurrency Lambda = số execution đang chạy cùng lúc.

- Nếu:

  - batch_size = 1
  - Và Lambda được phép chạy tối đa 5 execution song song
    → Tại 1 thời điểm, Lambda có thể xử lý tối đa 5 message song song (mỗi execution 1 message).
- Nếu:

  - batch_size = 5
  - Tối đa 5 execution song song
    → Tại 1 thời điểm, Lambda đang xử lý tối đa 25 message:
    - 5 execution × 5 message/batch.
    - Mỗi execution xử lý 5 record trong event.Records (thường là lần lượt).

##### 4. Các “núm vặn” để giới hạn song song

- batch_size trong Event Source Mapping:

  - 1 → mỗi execution 1 message.
_  -   1 → mỗi execution nhiều message.
_
- reserved_concurrent_executions trên Lambda:

  - Giới hạn số execution tối đa chạy cùng lúc cho function.
- (Nếu có) scaling_config.maximum_concurrency trên Event Source Mapping:

  - Giới hạn số poller song song trên queue đó.
    
Kết hợp:

  - Muốn tối đa N message song song:
    - Đặt batch_size = 1.
    - Đặt reserved_concurrent_executions = N (và/hoặc maximum_concurrency = N).

##### 5. Retry với SQS (khác với async S3/SNS)
- Với SQS:
  - Retry không dùng maximum_retry_attempts của Lambda async.
  - Khi execution fail (throw error):
    - Batch message không bị xoá khỏi queue.
    - Sau khi hết VisibilityTimeout, SQS giao lại message → Lambda được invoke lại (retry).
    - Số lần giao lại phụ thuộc redrive policy của SQS (maxReceiveCount), sau đó message chuyển sang DLQ của SQS (nếu cấu hình).
   
---

## 1. Kiến trúc tổng quan của lab

### 1.1. Thành phần

**1. Lambda A – sync-api-lambda**

  - Ngôn ngữ: Node.js 18.
  - Invoke: synchronous qua HTTP API Gateway.
  - Route: GET /test.
  - Cấu hình:
    - publish = true.
    - Alias: prod.
    - **Provisioned Concurrency = 5** (trên alias prod).
    - Có thể đặt reserved_concurrent_executions để giới hạn concurrency tối đa.
      
**2. Lambda B – async-s3-lambda**

  - Ngôn ngữ: Node.js 18.
  - Invoke: asynchronous từ S3 bucket.
  - Trigger: s3:ObjectCreated:*.
  - Cấu hình:
    - maximum_retry_attempts = 2.
    - Event thất bại sau retry → gửi vào SQS DLQ async-s3-lambda-dlq.
      
**3. Tài nguyên khác**

  - HTTP API Gateway: demo-sync-api.
  - S3 bucket: demo-lambda-concurrency-<random>.
  - SQS DLQ: async-s3-lambda-dlq.
  - IAM Role cho Lambda.
---

## 2. Workflow & Khái niệm trong lab

### 2.1. Sync Lambda A (sync-api-lambda)

Workflow:
```text
[Client] 
   |
   | 1. HTTP GET /test
   v
[API Gateway HTTP API: demo-sync-api]
   |
   | 2. Invoke Lambda alias prod (AWS_PROXY)
   v
[Lambda A: sync-api-lambda:prod]
   |
   | 3. Xử lý:
   |    - Log EVENT
   |    - Sleep 2s (mô phỏng xử lý lâu)
   | 4. Trả về {statusCode: 200, body: JSON}
   v
[API Gateway]
   |
   | 5. HTTP 200 + JSON
   v
[Client]

```
Concurrency:

  - Ví dụ reserved_concurrent_executions = 5:
    - Tối đa 5 request được xử lý song song.
    - Request thứ 6 trở lên (khi 5 cái đầu chưa xong) → Lambda bị throttle (Rate Exceeded).
  - Provisioned Concurrency = 5:
    - 5 instance luôn “ấm sẵn” → gần như không có cold start cho 5 request đầu.

### 2.2. Async Lambda B (async-s3-lambda) + DLQ

Workflow thành công:
```text
[Client / System]
   |
   | 1. PUT object (file_X.txt)
   v
[S3 Bucket: demo-lambda-concurrency-xxxx]
   |
   | 2. Phát event ObjectCreated:Put
   v
[Lambda B: async-s3-lambda]
   |
   | 3. Nhận event, log "S3 Event: ..."
   |    - Đọc bucket, key
   |    - Xử lý business
   v
[Hoàn thành]

```

Workflow lỗi + DLQ (khi cố tình throw new Error("Simulated processing error")):
```text
[S3 Bucket] --ObjectCreated--> [Lambda B: async-s3-lambda]
                                   |
                                   | 1. Handler chạy -> throw Error
                                   v
                          [Lambda Async Retry Logic]
                                   |
                                   | 2. Retry tối đa 2 lần
                                   v
                [SQS DLQ: async-s3-lambda-dlq (on_failure destination)]
                                   |
                                   | 3. Event S3 gốc được lưu trong DLQ
                                   v
                    [Consumer khác / người vận hành đọc & xử lý lại]

```

## 3. Cấu trúc thư mục
```text

project/
  main.tf
  lambda_sync.js
  lambda_async.js
  test_concurrency.py   # (tùy chọn, để benchmark concurrency)
```

---

## 4. Ghi chú & Mở rộng

**Sync (sync-api-lambda):**

  - 1 request = 1 invoke.
  - Không auto retry phía Lambda khi lỗi.
    
**Async (async-s3-lambda):**

  - Có auto retry theo maximum_retry_attempts.
  - Sau đó failure → DLQ / Event Destination.
    
**Tuần tự vs song song:**

  - Muốn xử lý tuần tự (1 message một lúc) từ SQS:
    - reserved_concurrent_executions = 1 cho Lambda.
    - Event source mapping batch_size = 1.
  - Muốn xử lý tối đa N message song song:
    - reserved_concurrent_executions = N.
    - Event source mapping:
      - batch_size = 1.
      - (Nếu hỗ trợ) scaling_config.maximum_concurrency = N.
---

## 5. Triển khai (Deploy) một AWS Lambda Function

### 5.1. Các cách deploy phổ biến

Có nhiều cách để deploy Lambda, trong đó 2 cách hay dùng trong thực tế:

  1. **Sử dụng SDK / CLI (imperative)**

  - Ví dụ: AWS SDK (Node.js, Python), hoặc aws lambda create-function / update-function-code.
  - Phù hợp cho:
    - Script CI/CD đơn giản.
    - Tool nội bộ tự động build & push code.
      
  2. **Sử dụng IaC (Infrastructure as Code) – Terraform, CloudFormation, CDK (declarative)**

  - Khai báo hạ tầng + code bằng file cấu hình / code.
  - Phù hợp cho:
    - Môi trường production / nhiều môi trường (dev, staging, prod).
    - Team DevOps muốn version control toàn bộ hạ tầng.
      
Trong lab này chúng ta dùng Terraform, nhưng dưới đây là so sánh ngắn và ví dụ cho cả 2.


### 5.2. Deploy Lambda bằng SDK / CLI (imperative)

**a) Ý tưởng**

  - Bạn build/zip code Lambda → upload lên AWS bằng SDK hoặc CLI.
  - Nếu function chưa tồn tại → create-function.
  - Nếu function đã tồn tại → update-function-code (và tùy chọn publish version mới).
    
**b) Ví dụ với AWS CLI (Python/Node đều giống ý tưởng)**

Giả sử:

  - Code nằm trong lambda_sync.js.
  - Bạn zip lại thành lambda_sync.zip.
    
```bash
zip lambda_sync.zip lambda_sync.js

```

Tạo function lần đầu:

```bash
aws lambda create-function \
  --function-name my-sync-lambda \
  --runtime nodejs18.x \
  --role arn:aws:iam::<ACCOUNT_ID>:role/demo-lambda-exec-role \
  --handler lambda_sync.handler \
  --zip-file fileb://lambda_sync.zip \
  --timeout 10 \
  --memory-size 256

```

Update code (mỗi lần sửa):

```bash
zip lambda_sync.zip lambda_sync.js

aws lambda update-function-code \
  --function-name my-sync-lambda \
  --zip-file fileb://lambda_sync.zip \
  --publish

_"--publish sẽ tạo một version mới của Lambda (VD: 1, 2, 3,…)."_

```

**c) Ví dụ bằng SDK Node.js (tự động deploy từ script)**
```js
// deploy_lambda.js
const fs = require("fs");
const path = require("path");
const { LambdaClient, UpdateFunctionCodeCommand } = require("@aws-sdk/client-lambda");

const lambda = new LambdaClient({ region: "ap-southeast-1" });

async function deploy() {
  const zipFile = fs.readFileSync(path.join(__dirname, "lambda_sync.zip"));

  const cmd = new UpdateFunctionCodeCommand({
    FunctionName: "my-sync-lambda",
    ZipFile: zipFile,
    Publish: true, // tạo version mới
  });

  const res = await lambda.send(cmd);
  console.log("Deployed. New version:", res.Version);
}

deploy().catch(console.error);

```
Chạy:

```bash
node deploy_lambda.js
```

### 5.3. Deploy Lambda bằng Terraform (declarative)

Trong lab, chúng ta sử dụng Terraform để:

  - Định nghĩa function, IAM role, trigger, API Gateway, S3, SQS DLQ, provisioned concurrency.
  - Mọi thứ được quản lý bằng code, lưu trên Git, có thể review/rollback.
    
Ví dụ khai báo Lambda bằng Terraform (đã dùng trong lab):
```hcl
data "archive_file" "lambda_sync_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda_sync.js"
  output_path = "${path.module}/lambda_sync.zip"
}

resource "aws_lambda_function" "sync_api_lambda" {
  function_name = "sync-api-lambda"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_sync.handler"
  runtime       = "nodejs18.x"

  filename         = data.archive_file.lambda_sync_zip.output_path
  source_code_hash = data.archive_file.lambda_sync_zip.output_base64sha256

  # reserved_concurrent_executions = 20  # nếu cần
  memory_size = 256
  timeout     = 10

  publish = true
}

```

Khi sửa code lambda_sync.js:

Chỉ cần chạy:
```bash
terraform apply

```

**So sánh nhanh SDK vs Terraform**

---

## 6. Monitoring & Observability cho Lambda

Monitoring giúp bạn hiểu:

  - Lambda đang chạy tốt hay không?
  - Concurrency có bị full không?
  - Có bị throttle, lỗi nhiều không?
  - Thời gian chạy (duration) và lỗi (error) như thế nào?
    
AWS cung cấp các công cụ chính:

  - CloudWatch Logs – log chi tiết từng invoke.
  - CloudWatch Metrics – metric tổng quan (Invocations, Errors, Duration,…).
  - X-Ray – trace, profiling chi tiết (tuỳ chọn).

### 6.1. CloudWatch Logs

Mỗi Lambda function mặc định log vào CloudWatch Logs (nhờ policy AWSLambdaBasicExecutionRole):

  - Log group: /aws/lambda/<function_name>.
  - Mỗi container/instance có log stream riêng.
    
Dùng CLI:
```bash
aws logs tail "/aws/lambda/sync-api-lambda" --since 5m

```

Trong log bạn thường thấy:

  - START RequestId: ...
  - Log của bạn: console.log(...), console.error(...).
  - END RequestId: ...
  - REPORT RequestId: ... Duration: ... ms ...
