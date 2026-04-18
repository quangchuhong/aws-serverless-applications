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
