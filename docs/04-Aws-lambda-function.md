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
