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
