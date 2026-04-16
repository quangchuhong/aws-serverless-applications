# Tài liệu: Amazon AppFlow & Backup dữ liệu SaaS (ví dụ GitLab)

## 1. Amazon AppFlow là gì?

- Dịch vụ **managed** của AWS để **kéo/đẩy dữ liệu** giữa:
  - Các ứng dụng SaaS: Salesforce, Zendesk, ServiceNow, Slack, v.v.
  - Các dịch vụ AWS: **S3, Redshift, Snowflake (qua S3)**,...
- Mục tiêu: **tập trung dữ liệu** về AWS để:
  - Phân tích dữ liệu lớn / BI / ML.
  - Lưu trữ lâu dài / audit / compliance.
- Cấu hình dạng **no-code/low-code** trên AWS Console (flow, mapping, schedule).

---

## 2. Dữ liệu SaaS là gì?

- **SaaS (Software as a Service)**: phần mềm dùng qua internet, chạy trên hạ tầng của nhà cung cấp (Salesforce, Zendesk, HubSpot, GitLab.com,...).
- **Dữ liệu SaaS**: các bảng, record, log, event bên trong các hệ thống đó:
  - Ví dụ: leads, tickets, issues, merge requests, users, logs, events,...

---

## 3. AppFlow & backup/restore

### 3.1. Ý nghĩa “backup” bằng AppFlow

- **Export dữ liệu SaaS → AWS (S3/Redshift)**:
  - Lưu trữ lâu dài, chủ động (data ownership).
  - Phân tích, BI, ML (kết hợp nhiều nguồn dữ liệu).
  - Hỗ trợ tuân thủ (audit trail, lưu nhiều năm).
  - Hỗ trợ migrate/khôi phục 1 phần khi cần.

> AppFlow **không phải** công cụ backup/restore full state ứng dụng như backup database.

### 3.2. Khả năng restore

- Một số connector hỗ trợ cả 2 chiều:
  - **SaaS → AWS** (đọc dữ liệu).
  - **AWS → SaaS** (ghi/update record).
- Có thể **import lại một phần dữ liệu** (contacts, leads, tickets,...) nhưng:
  - Không đảm bảo **restore point-in-time** toàn hệ thống.
  - Không khôi phục đầy đủ logic app (workflow, rule, permission,...).
  - Cần tự thiết kế chiến lược khôi phục, mapping field, xử lý conflict.

---

## 4. Định dạng dữ liệu khi AppFlow backup về S3

- Khi **destination = Amazon S3**, có thể chọn:
  - **CSV**
  - **JSON**
  - **Parquet** (tối ưu cho data lake / query lớn)
- Tùy chọn:
  - Cách chia file (số bản ghi/kích thước).
  - Cấu trúc folder (theo ngày/tháng/năm, theo field, v.v.).

Khi đẩy về:
- **Redshift** → vào **bảng** (table), không phải file.
- **SaaS khác** → ghi record qua API, không ra file trung gian cho bạn.

---

## 5. Ví dụ: backup dữ liệu GitLab về S3

### 5.1. Lưu ý về GitLab & AppFlow

- AppFlow **chưa có connector GitLab native**.
- Muốn backup GitLab → S3 có 2 hướng chính:
  1. **Lambda + GitLab API + S3** (thực tế đơn giản, phổ biến).
  2. **AppFlow Custom Connector** gọi GitLab API (phức tạp hơn, dùng khi cần tích hợp chặt với AppFlow).

> Việc “sử dụng AppFlow backup cho GitLab” thực chất là:  
> tạo **Custom Connector** hoặc intermediate API (Lambda/API Gateway),  
> rồi AppFlow kết nối vào đó. AppFlow không gọi GitLab API trực tiếp chỉ bằng token nếu không có connector.

### 5.2. Các nhóm dữ liệu GitLab thường backup

Một số loại dữ liệu hay trích xuất:

- **Projects**
- **Issues**
- **Merge Requests**
- **Commits (metadata)**
- **Users / Members**

### 5.3. Ví dụ dữ liệu JSON GitLab lưu trên S3

**Issues – JSON:**

```json
[
  {
    "id": 12345,
    "iid": 7,
    "project_id": 42,
    "title": "API endpoint returns 500",
    "description": "Steps to reproduce...",
    "state": "opened",
    "labels": ["bug", "high-priority"],
    "assignee": {
      "id": 101,
      "username": "jdoe"
    },
    "author": {
      "id": 99,
      "username": "alice"
    },
    "created_at": "2026-04-15T10:23:45Z",
    "updated_at": "2026-04-16T08:11:02Z",
    "web_url": "https://gitlab.example.com/group/project/-/issues/7"
  }
]
```

**Merge Requests – CSV:**
```csv
id,iid,project_id,title,state,author_username,created_at,merged_at
9876,15,42,"Add user audit log","merged","alice","2026-04-10T09:00:00Z","2026-04-11T14:20:30Z"
9877,16,42,"Refactor auth module","opened","jdoe","2026-04-12T07:15:00Z",

```

**Projects – JSON:**
```csv
[
  {
    "id": 42,
    "name": "payment-service",
    "path_with_namespace": "backend/payment-service",
    "visibility": "private",
    "description": "Microservice for payment processing",
    "default_branch": "main",
    "web_url": "https://gitlab.example.com/backend/payment-service",
    "created_at": "2024-03-01T08:00:00Z",
    "last_activity_at": "2026-04-16T07:30:12Z"
  }
]

```

### 5.4. Gợi ý tổ chức folder trên S3

Ví dụ cấu trúc:
```text
s3://<bucket-name>/gitlab/projects/2026-04-16/projects.json
s3://<bucket-name>/gitlab/issues/2026-04-16/issues.json
s3://<bucket-name>/gitlab/merge_requests/2026-04-16/merge_requests.csv

```
Hoặc phân vùng theo năm/tháng/ngày:
```text
gitlab/issues/year=2026/month=04/day=16/issues.parquet

```
---

## 6. Tóm tắt

- **AppFlow:**

  - Là công cụ data integration để kéo dữ liệu SaaS về AWS (S3, Redshift, Snowflake,...) phục vụ analytics.
  - Hỗ trợ backup dạng data copy/snapshot, không phải full app restore.
    
- **Backup GitLab:**

  - Không có connector AppFlow sẵn → cần:
    - Lambda + GitLab API + S3, hoặc
    - Custom Connector AppFlow gọi GitLab API.
      
  - Lưu dữ liệu dạng JSON/CSV/Parquet trên S3, dễ dàng phân tích & lưu trữ dài hạn.
