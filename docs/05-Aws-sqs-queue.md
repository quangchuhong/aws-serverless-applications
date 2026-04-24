# Lý thuyết Amazon SQS & Cấu hình quan trọng

## 1. Phân loại SQS

### 1.1. Standard Queue

  - Thông lượng rất cao (gần như không giới hạn).
  - Best-effort ordering: cố gắng giữ thứ tự, nhưng không đảm bảo tuyệt đối.
  - At-least-once delivery: 1 message có thể được giao nhiều hơn 1 lần (duplicate).
  - Dùng khi:
    - Không cần thứ tự tuyệt đối.
    - Chấp nhận hoặc xử lý được duplicate.
      
### 1.2. FIFO Queue (*.fifo)

 - Đảm bảo:
  - Exactly-once processing (ở mức SQS – không duplicate nếu xử lý đúng).
  - Thứ tự nghiêm ngặt per MessageGroupId.
- Thông lượng thấp hơn Standard (nhưng vẫn đủ lớn với đa số use case).
- Dùng khi:
  - Cần thứ tự.
  - Không muốn/khó xử lý duplicate.
  - Ví dụ: xử lý giao dịch theo user/account, order.

---

## 2. Nhóm cấu hình quan trọng của SQS

### 2.1. Visibility Timeout

**Ý nghĩa:**

Khi một consumer (ví dụ Lambda) nhận message:

  - Message “ẩn” (invisible) khỏi các consumer khác trong Visibility Timeout.
  - Nếu consumer xử lý xong & xóa message (DeleteMessage) trong thời gian này → message biến mất khỏi queue.
  - Nếu không (consumer chết, lỗi, timeout) → hết Visibility Timeout:
    - Message lại hiện ra cho consumer khác xử lý lại (retry).
      
**Thiết lập:**

  - Mặc định: 30s.
  - Tối đa: 12h.
  - Nên > (thời gian xử lý tối đa dự kiến của consumer).
    
**Best practice:**

  - Nếu Lambda timeout = 30s, xử lý max ~20s → Visibility Timeout nên ≥ 30–40s.
  - Tránh để Visibility quá thấp → message bị “phát lại” khi consumer vẫn đang xử lý.

### 2.2. Message Retention Period

**Ý nghĩa:**

  - Message tồn tại trong queue tối đa bao lâu (kể từ khi gửi).
  - Hết thời gian này mà chưa được xử lý/xóa → message bị SQS tự động xoá.
    
**Thiết lập:**

  - Min: 60s.
  - Max: 14 ngày.
  - Chọn theo:
    - SLA xử lý tối đa.
    - Dung lượng lưu trữ chấp nhận được.

### 2.3. Delivery Delay (Delay Seconds)

**Ý nghĩa:**

  - Mỗi message sau khi gửi vào queue sẽ bị delay một khoảng thời gian trước khi có thể được nhận.
  - Áp dụng:
    - Mặc định ở mức queue (mọi message).
    - Hoặc override per message (nếu API cho phép).
      
**Dùng khi:**

  - Bạn muốn trì hoãn xử lý (ví dụ: 5 phút sau mới bắt đầu).
  - Flow “retry sau X giây/phút” mà không dùng scheduler.

### 2.4. Maximum Message Size

  - Mặc định: 256 KB.
  - Có thể tăng lên (với “SQS Extended Client” dùng S3) nhưng phức tạp hơn.
  - Nếu payload lớn:
    - Thường: lưu dữ liệu lớn ở S3, trong SQS chỉ gửi metadata + S3 key.

### 2.5. Long Polling (ReceiveMessageWaitTimeSeconds)

**Ý nghĩa:**

  - Khi consumer gọi ReceiveMessage, nếu queue đang trống:
    - Long polling cho phép chờ (block) tới X giây (tối đa 20s) để đợi message mới đến.
    - Giảm số lần trả về “rỗng” → tiết kiệm chi phí request.
      
**Thiết lập:**

  - Ở mức queue: ReceiveMessageWaitTimeSeconds (0–20).
  - Ở mức từng request ReceiveMessage (override).
    
**Nên dùng:**

  - Hầu hết các trường hợp → giảm chi phí, giảm “empty receive”.

### 2.6. Redrive Policy (DLQ) – MaxReceiveCount

**Ý nghĩa:**

  - Khi 1 message liên tục bị đọc lại nhiều lần nhưng không được xóa (tức xử lý fail liên tục):

    - Ta không muốn nó kẹt mãi làm rác queue.
    - Redrive policy cho phép tự chuyển message lỗi sang Dead-Letter Queue (DLQ) sau X lần nhận.
      
**Cấu hình:**

  - Cần 1 DLQ (thường cũng là SQS khác).
  - Set trong Redrive Policy:
    - maxReceiveCount: số lần tối đa message được nhận mà không bị xóa trước khi bị chuyển sang DLQ.
    - deadLetterTargetArn: ARN của DLQ.
      
**Ví dụ:**

  - maxReceiveCount = 5:
    - Message được consumer nhận tối đa 5 lần.
    - Nếu mỗi lần đều fail (không xoá) → lần thứ 6, SQS chuyển message sang DLQ.

### 2.7. Message Group & Deduplication (FIFO)

Chỉ áp dụng cho FIFO queue.

**a) MessageGroupId**

  - Dùng để nhóm message có liên quan.
  - SQS đảm bảo thứ tự cho từng group:
    - Cùng MessageGroupId → xử lý đúng thứ tự gửi.
    - Group khác nhau có thể xử lý song song.
      
**Ví dụ:**

  - MessageGroupId = user-123 → mọi event của user 123 được xử lý theo thứ tự.
  - MessageGroupId = order-xyz → mọi event của order xyz theo thứ tự.
    
**b) DeduplicationId**

  - Tránh message trùng lặp.
  - Mỗi DeduplicationId trong 1 khoảng thời gian dedup (mặc định 5 phút) chỉ được xử lý 1 lần.
  - Có thể:
    - Cho phép SQS tự động dùng nội dung message để dedup (ContentBasedDeduplication = true).
    - Hoặc bạn tự set MessageDeduplicationId.

### 2.8. Encryption

  - SQS hỗ trợ KMS encryption at rest:

    - Bật encryption để mã hóa message khi lưu trong SQS.
    - Chọn KMS key (AWS-managed hoặc customer-managed).
  - Không ảnh hưởng nhiều tới logic ứng dụng, chủ yếu liên quan compliance/bảo mật.

---

## 3. Tóm tắt “config nào để làm gì?”

**Standard vs FIFO:**

  - Standard: throughput cao, không đảm bảo thứ tự, có thể duplicate.
  - FIFO: thứ tự + exactly-once (ở mức SQS), throughput thấp hơn.
    
**Visibility Timeout:**

  - Thời gian message “ẩn” sau khi được nhận.
  - Cần > thời gian xử lý tối đa của consumer.
    
**Message Retention Period:**

  - Tối đa message ở lại queue bao lâu trước khi bị auto-delete.
    
**Delivery Delay:**

  - Trì hoãn xử lý message X giây/phút sau khi gửi.
    
**Long Polling:**

  - Chờ message mới khi queue trống, giảm empty receive & chi phí.
    
**Redrive Policy (DLQ, MaxReceiveCount):**

  - Tự động chuyển message lỗi sang DLQ sau N lần nhận thất bại.
    
**FIFO – MessageGroupId / DeduplicationId:**

  - Group để đảm bảo thứ tự per group, và tránh duplicate.
---


## 3.1. Ứng dụng phù hợp với SQS Standard (chấp nhận / xử lý được duplicate)

SQS Standard có đặc tính **at-least-once delivery** → message **có thể bị xử lý nhiều hơn một lần**.  
Những loại ứng dụng sau thường **chấp nhận được** (hoặc dễ xử lý) duplicate, nên rất hợp dùng Standard queue:

### 3.1.1. Hệ thống gửi thông báo: Email / SMS / Push / Notification

- Ví dụ:
  - Gửi email marketing, email nhắc việc.
  - Gửi SMS OTP/notification.
  - Gửi push notification lên mobile app.
- Nếu bị gửi lại 2 lần:
  - Thường **không làm hỏng dữ liệu lõi** (chỉ hơi “phiền” cho user).
  - Có thể giảm duplicate bằng logic phía service gửi (log đã gửi, không gửi lại trong X phút,…).

### 3.1.2. Background job không phá dữ liệu (task queue)

- Ví dụ:
  - Resize ảnh, tạo thumbnail.
  - Chuyển đổi video/audio (transcoding).
  - Generate báo cáo PDF, export file.
  - Index/reindex dữ liệu vào search (Elasticsearch/OpenSearch).
- Nếu 1 job chạy lại:
  - Thumbnail tạo lại → ghi đè file cũ.
  - Reindex lại → ghi đè document cũ.
  - Generate báo cáo → ghi đè file kết quả.
- → Job dạng này **tự nhiên idempotent** (chạy lại cũng không sao).

### 3.1.3. Log, metrics, analytics, event tracking

- Ví dụ:
  - Ghi log hoạt động user.
  - Gửi metric, event tracking, clickstream.
- Nếu event bị gửi 2 lần:
  - Chỉ tạo thêm dòng log hoặc thêm 1 event cho hệ thống analytics.
  - Thường **không phá dữ liệu nghiệp vụ**.
- Có thể:
  - Chấp nhận sai số nhỏ trong analytics, hoặc
  - Dùng cơ chế dedup ở downstream (dựa trên eventId).

### 3.1.4. Worker pool / batch job không ràng buộc giao dịch

- Ví dụ:
  - Crawler đọc dữ liệu từ API ngoài rồi lưu vào cache.
  - Job sync dữ liệu định kỳ với hệ thống bên ngoài.
  - Gửi webhook sang hệ thống khác để cập nhật trạng thái.
- Nếu job bị chạy lại:
  - Thường là **gọi lại API / sync lại dữ liệu** → không phá dữ liệu nếu thiết kế đúng (upsert, overwrite,…).

### 3.1.5. Các hệ thống đã thiết kế idempotent ở tầng ứng dụng

- Consumer đọc message, nhưng **tự đảm bảo idempotency**, ví dụ:
  - Mỗi message có `eventId` hoặc `transactionId` duy nhất.
  - Trước khi xử lý, consumer check trong DB:
    - Nếu đã xử lý `eventId` đó → bỏ qua.
    - Nếu chưa → xử lý và ghi log là đã xử lý.
- Kết quả:
  - Dù Standard queue giao cùng 1 message **nhiều lần**, ứng dụng **chỉ tính là 1 lần xử lý thực sự**.

### Kết luận lựa chọn

- Dùng **SQS Standard** khi:
  - Cần **throughput rất cao**.
  - Không cần thứ tự tuyệt đối.
  - Duplicate:
    - Hoặc **không phá** hệ thống (log, email, thumbnail, reindex,…), hoặc
    - Đã có **idempotency** phía backend (transactionId/eventId, upsert, check-before-write,…).

- Nếu duplicate có thể gây:
  - Double charge tiền.
  - Double trừ tồn kho.
  - Làm sai trạng thái đơn hàng/giao dịch.
  
  → Nên:
  - Dùng **FIFO queue** với `MessageGroupId`, **hoặc**
  - Dùng Standard nhưng **bắt buộc** consumer phải idempotent rất chặt.
---

## 3.2. Ứng dụng phù hợp với SQS FIFO (thứ tự & không duplicate)

SQS FIFO có đặc tính:

- **First-in-first-out**: đảm bảo thứ tự gửi–nhận **nghiêm ngặt per `MessageGroupId`**.
- **Exactly-once processing (ở mức queue)**: không tự sinh duplicate trong queue nếu cấu hình dedup đúng.

Những loại ứng dụng sau rất phù hợp dùng FIFO:

### 3.2.1. Order / E‑commerce / Thanh toán

- Ví dụ:
  - Xử lý luồng đơn hàng:  
    `ORDER_CREATED → PAYMENT_AUTHORIZED → PAYMENT_CAPTURED → SHIPPED → DELIVERED`.
- Yêu cầu:
  - Không “SHIP trước khi PAYMENT_CAPTURED”.
  - Không xử lý 2 lần cùng một payment (double charge).
- Gợi ý:
  - FIFO queue với `MessageGroupId = orderId` hoặc `userId`.

### 3.2.2. Giao dịch tài chính: Banking / Ví điện tử / Billing

- Ví dụ:
  - Giao dịch theo tài khoản: nạp tiền, rút tiền, chuyển tiền, hoàn tiền.
- Yêu cầu:
  - Giao dịch phải xử lý theo **thứ tự** để số dư luôn đúng.
  - Không double apply 1 giao dịch (không trừ tiền 2 lần).
- Gợi ý:
  - FIFO queue với `MessageGroupId = accountId`.

### 3.2.3. Hệ thống đặt chỗ / booking

- Ví dụ:
  - Đặt vé máy bay, khách sạn, sự kiện, chỗ ngồi, slot tài nguyên.
- Yêu cầu:
  - Cập nhật trạng thái chỗ trống theo đúng thứ tự request.
  - Tránh overbook do xử lý đảo thứ tự hoặc do duplicate.
- Gợi ý:
  - FIFO queue với `MessageGroupId = bookingId` hoặc `resourceId`.

### 3.2.4. Workflow tuần tự theo user/tenant

- Ví dụ:
  - Pipeline xử lý dữ liệu cho từng user/tenant:  
    `UPLOAD → VALIDATE → TRANSFORM → EXPORT`.
- Yêu cầu:
  - Với mỗi user, các bước phải **diễn ra theo đúng trình tự**.
- Gợi ý:
  - FIFO queue với `MessageGroupId = userId` hoặc `tenantId`.

### 3.2.5. Event sourcing / audit theo entity

- Ví dụ:
  - Chuỗi event cho 1 entity (user, order, device, document, …):
    - `CREATED → UPDATED → UPDATED → DELETED`.
- Yêu cầu:
  - Event của từng entity phải theo đúng **timeline**.
  - Không nhân đôi 1 event gây double apply.
- Gợi ý:
  - FIFO queue với `MessageGroupId = entityId`.

### 3.2.6. Command/Control cho thiết bị / session (IoT, game, control system)

- Ví dụ:
  - Lệnh điều khiển cho từng device/session:  
    `connect`, `start`, `update-config`, `stop`.
- Yêu cầu:
  - Không “stop trước khi start”.
  - Không bắn 2 lần cùng 1 command quan trọng nếu không idempotent.
- Gợi ý:
  - FIFO queue với `MessageGroupId = deviceId` hoặc `sessionId`.

### 3.2.7. Đồng bộ dữ liệu nhạy cảm theo thứ tự

- Ví dụ:
  - Đồng bộ trạng thái entity từ hệ thống nguồn sang hệ thống đích:  
    `CREATE → UPDATE → UPDATE → DELETE`.
- Yêu cầu:
  - Không xử lý UPDATE sau DELETE.
  - Không áp dụng cùng 1 UPDATE/DELETE nhiều lần nếu không idempotent.
- Gợi ý:
  - FIFO queue với `MessageGroupId = entityId`.

### Kết luận lựa chọn

- Nếu 1 entity (user/order/account/booking/device/…) có **chuỗi event/command cần thứ tự nghiêm ngặt** và:
  - Duplicate **có thể gây lỗi nghiêm trọng** (double charge, sai trạng thái, sai số dư), hoặc
  - Rất khó làm idempotent ở tầng ứng dụng

→ Rất phù hợp dùng **SQS FIFO** với:

- `MessageGroupId` = ID của entity (userId, orderId, accountId, …).
- (Tùy nhu cầu) `ContentBasedDeduplication` hoặc `MessageDeduplicationId` để tránh duplicate.



---

## 4. Flow tổng thể: API Gateway → SQS Standard → Lambda

```text
[Client]
   |
   |  HTTP Request
   v
[API Gateway]
   |
   | 1. Gửi message (SendMessage) tới SQS
   v
[SQS Standard Queue]
   |  (lưu message, áp dụng: 
   |   - Delivery Delay
   |   - Maximum Message Size
   |   - Encryption
   |   - Message Retention Period
   |   - Redrive Policy (DLQ) khi maxReceiveCount)
   |
   | 2. Event Source Mapping (poll)
   |    - Long Polling
   |    - batch_size
   v
[Lambda Consumer]
   |  (xử lý message trong Visibility Timeout)
   |
   | 3a. Thành công -> DeleteMessage
   |      -> message biến mất
   |
   | 3b. Lỗi / timeout -> không Delete
   |      -> hết Visibility Timeout -> message hiện lại
   |      -> ReceiveCount tăng
   |      -> nếu ReceiveCount > MaxReceiveCount ->
   v                                  chuyển sang DLQ
[SQS DLQ (Dead-Letter Queue)]

```

### 4.1. Giai đoạn API Gateway nhận request & gửi vào SQS
```text
[Client] ---> [API Gateway] ---> [SQS Standard Queue]
                       (producer)

```

- **API Gateway** (hoặc Lambda/Service phía sau API GW) là **producer**:

  - Nhận HTTP request.
  - Validate, parse payload.
  - Gọi SendMessage tới SQS Standard Queue.
    
- Tại thời điểm SendMessage, các option liên quan:

  - Maximum Message Size
    - Payload gửi vào SQS tối đa 256 KB.
    - Nếu dữ liệu lớn hơn:
      - Thường: lưu nội dung lớn ở S3, trong message chỉ chứa S3 key / metadata.
        
  - Delivery Delay
    - Có thể cấu hình:
      - Ở mức queue: mọi message bị delay X giây.
      - Hoặc per-message (qua DelaySeconds trong SendMessage).
    - Trong thời gian delay:
      - Message chưa visible, consumer chưa đọc được.
        
  - Encryption
    - Nếu bật KMS encryption:
      - Message được mã hóa at-rest khi lưu trong SQS.
      - Ứng dụng/consumer không cần làm gì thêm, SDK xử lý trong suốt.


### 4.2. Message nằm trong queue: Retention & Delay
```text
[SQS Standard Queue]
   |
   |-- Message mới đến:
   |     - Bị delay X giây (Delivery Delay)
   |     - Được mã hóa (Encryption) nếu bật
   |
   |-- Sau khi hết delay:
   |     - Trở thành "visible"
   |
   |-- Nếu không được xử lý / xóa trong Retention Period:
   |     - SQS auto delete (Message Retention Period)

```

Các option:

**1. Delivery Delay**

  - Trì hoãn thời điểm message trở thành visible.
  - Ví dụ: DelaySeconds = 60 → 60s sau khi gửi mới có thể được đọc.
    
**2. Message Retention Period**

  - Message ở trong queue tối đa X giây/ngày (1 phút – 14 ngày).
  - Nếu trong thời gian đó:
    - Không bị consumer xóa.
    - Và cũng không bị chuyển DLQ.
  - → Hết hạn → SQS tự động xóa message.
    
**3. Encryption**

  - Ảnh hưởng toàn bộ thời gian message lưu trong queue.
  - Không thay đổi cách code nhận/gửi.

### 4.3. Event Source Mapping & Long Polling (SQS → Lambda)
```text
[SQS Standard Queue]
   |
   |  Event Source Mapping
   |   - Long Polling
   |   - batch_size
   v
[Lambda Consumer]

```

- Event Source Mapping là cấu hình “Trigger” SQS → Lambda:

  - Poll SQS theo ReceiveMessage.
  - Thường kết hợp Long Polling:
    - ReceiveMessageWaitTimeSeconds = 0–20s.
    - Khi queue trống, poll sẽ chờ X giây để đợi message mới → giảm empty receive.
- Khi poll được message:
  - Gom theo batch_size → 1 event Lambda:
```json
    {
  "Records": [
    { "body": "msg1", ... },
    { "body": "msg2", ... }
  ]
}

```
**Long Polling** ở đây:

- Giúp:
  - Giảm số request ReceiveMessage rỗng.
  - Tiết kiệm chi phí.
- Không ảnh hưởng đến logic xử lý message, chỉ là tối ưu IO.

## 4.4. Lambda xử lý & Visibility Timeout
```text
[Lambda Consumer]
   |
   |  Nhận event:
   |   {
   |     "Records": [ {msg1}, {msg2}, ... ]
   |   }
   |
   |-- Trong thời gian Visibility Timeout:
   |      - Message "ẩn" đối với consumer khác
   |
   |-- Nếu handler:
   |    a) Thành công:
   |        - Gọi DeleteMessage (Lambda runtime/ESM làm)
   |        - Message biến mất khỏi queue
   |
   |    b) Lỗi / timeout / throw:
   |        - Không DeleteMessage
   |        - Hết Visibility Timeout:
   |            + Message lại "hiện ra"
   |            + ReceiveCount++
   |            + Có thể được đọc lại (retry)

```

**Visibility Timeout:**

  - Thời gian “giữ chỗ” message khi một consumer đã nhận.
  - Phải được set > thời gian xử lý tối đa của Lambda.
  - Nếu Lambda chưa xóa message trước khi Visibility hết:
    - SQS cho phép consumer khác nhận → xem như retry.

### 4.5. Redrive Policy, DLQ & MaxReceiveCount
```text
[SQS Standard Queue]
   |
   |-- Message nhận nhiều lần nhưng luôn fail:
   |     ReceiveCount >= MaxReceiveCount
   v
[DLQ (Dead-Letter Queue)]

```

**Redrive Policy** trên queue chính:

- Thiết lập:
  - deadLetterTargetArn: ARN của queue DLQ.
  - maxReceiveCount: số lần tối đa message có thể được nhận (mà không bị xóa) trước khi bị chuyển DLQ.

**Flow:**

- Message được nhận lần 1:

  - Lambda lỗi → không xóa → Visibility Timeout hết → ReceiveCount = 1.
    
- Nhận lần 2:

  - Vẫn lỗi → ReceiveCount = 2.
    
- Nếu maxReceiveCount = 5:

  - Đến lần 5 vẫn fail → ReceiveCount = 5.
  - Lần 6, thay vì lại trả về cho consumer:
    - SQS chuyển message sang DLQ.
      
**Trong DLQ:**

- Bạn có thể:
  - Dùng Lambda/worker riêng đọc DLQ để xử lý đặc biệt.
  - Alert/monitor, phân tích message lỗi.


### 4.6. Maximum Message Size & Encryption trong toàn flow

- Maximum Message Size (256 KB):

  - Áp dụng khi SendMessage từ API Gateway/backend.
  - Nếu payload > 256 KB:
    - Pattern thường dùng:
      - Lưu nội dung lớn ở S3.
      - Trong SQS chỉ đặt metadata + S3 URL/key.
        
- Encryption (KMS):

  - Áp dụng khi message được lưu trong SQS (at rest).
  - Trong suốt toàn bộ vòng đời message:
    - Từ lúc gửi → lưu trữ → nhận lại → xoá/chuyển DLQ.
  - Không đổi cách code; chỉ cần IAM/KMS policy phù hợp.

---

## So sánh Standard Queue vs FIFO Queue

| Tiêu chí                    | Standard Queue                                                                 | FIFO Queue                                                                                                   |
|-----------------------------|-------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| Thông lượng (Throughput)   | **Gần như không giới hạn** TPS per API action.                               | **Cao nhưng giới hạn**: ~300 msg/s (send/receive/delete). Nếu batch 10 msg/operation → ~3,000 msg/s.       |
| Thứ tự (Ordering)          | **Best-effort ordering**: cố gắng giữ thứ tự nhưng **thỉnh thoảng có thể lệch**. | **First-in-first-out (FIFO)**: thứ tự gửi – nhận được **bảo toàn nghiêm ngặt** (per MessageGroupId).      |
| Giao hàng (Delivery)       | **At-least-once delivery**: mỗi message được giao **ít nhất 1 lần**, đôi khi >1 lần (có duplicate). | **Exactly-once processing**: mỗi message được giao **một lần**, giữ nguyên trong queue đến khi consumer xử lý & xóa; **không tự sinh duplicate** trong queue. |
| Use case điển hình         | Tải rất lớn, không cần thứ tự tuyệt đối, xử lý được duplicate.               | Cần thứ tự nghiêm ngặt, tránh duplicate, luồng giao dịch/order theo user, account, đơn hàng,…              |

