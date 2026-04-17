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
