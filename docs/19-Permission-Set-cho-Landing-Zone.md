# Permission Set cho Landing Zone

Ví dụ 19: Thiết kế và triển khai 17 permission set cho toàn bộ LZ, gán theo group qua IAM Identity Center.

> Code: [`landing-zone/permission-sets/`](../landing-zone/permission-sets/). Nền tảng Organizations/OU/SCP ở [06 – AWS Landing Zone](./06-Aws-Landing-Zone.md). Trường hợp có AD on-premise ở [08 – Đồng bộ user AD](./08-Dong-bo-User-AD-sang-IAM-Identity-Center.md).

---

## 0. Trạng thái triển khai

| Phần | Trạng thái |
|---|---|
| 17 permission set, code đầy đủ | ✅ Đã viết |
| Ma trận gán theo group | ✅ Đã viết |
| Chốt PassRole, Deny list, guardrail | ✅ Đã viết |
| Kiểm chứng JSON policy (17/17 hợp lệ) | ✅ Đã chạy |
| `terraform fmt` | ✅ Sạch |
| `terraform validate` / `plan` | ⏸ Chưa chạy được — registry Terraform bị chặn trong môi trường soạn tài liệu |
| Permissions boundary (`lz-boundary`) | ⬜ Cần StackSet đẩy xuống mọi account trước khi bật |
| Tự động hoá break-glass (tạo/gỡ assignment) | ⬜ Chưa làm |

---

## 1. Bảng 17 permission set

Xuất phát từ bảng thiết kế 15 set, thêm 2 set sau khi rà soát (mục 3.4 và 2.2).

| # | Permission set | Phạm vi | Phiên | Nền |
|---|---|---|---|---|
| 1 | `lz-account-admin` | All | 1h | `AdministratorAccess` |
| 2 | `lz-billing` | Management | 4h | `job-function/Billing` |
| 3 | `lz-auditor` | All | 8h | `ViewOnlyAccess` + `SecurityAudit` |
| 4 | `lz-network-admin` | All | 4h | `NetworkAdministrator` + inline |
| 5 | `lz-network-operator` | All | 8h | `ViewOnlyAccess` + inline |
| 6 | `lz-security-admin` | All | 1h | inline |
| 7 | `lz-security-operator` | All | 8h | `SecurityAudit` + `ViewOnlyAccess` |
| 8 | `lz-server-admin` | All | 4h | inline |
| 9 | `lz-server-operator` | All | 8h | `ViewOnlyAccess` + inline |
| 10 | `lz-db-admin` | All | 1h | inline |
| 11 | `lz-db-operator` | All | 8h | `ViewOnlyAccess` + inline |
| 12 | `lz-analytics-admin` | Analytics | 4h | inline |
| 13 | `lz-analytics-operator` | Analytics | 8h | `ViewOnlyAccess` + inline |
| 14 | `lz-app-admin` | **Non-Prod** | 4h | inline |
| 15 | `lz-app-operator` | **Prod** | 8h | `ViewOnlyAccess` + inline |
| 16 | `lz-datalake-admin` ⭐ | Analytics | 1h | inline |
| 17 | `lz-app-breakglass` ⭐ | **không gán sẵn** | 1h | inline |

⭐ = thêm mới so với bảng gốc.

Cấu trúc thật của bảng là **ma trận hai chiều**: (miền × cấp quyền) × (loại account).

```
            account-admin ─────────────────────────── mọi miền, mọi account
            auditor ───────────────────────────────── mọi miền, chỉ đọc
                        ┌──────────┬──────────┐
                        │  admin   │ operator │
            ┌───────────┼──────────┼──────────┤
   miền     │ network   │    4     │    5     │  All
            │ security  │    6     │    7     │  All
            │ server    │    8     │    9     │  All
            │ database  │   10     │   11     │  All
            │ analytics │   12     │   13     │  Analytics
            │ app       │   14     │   15     │  Non-Prod / Prod  ← khác
            └───────────┴──────────┴──────────┘
```

Hàng cuối là hàng khác biệt, và nó chứa quyết định quan trọng nhất của cả thiết kế.

---

## 2. Quyết định lớn nhất: production không ai ghi được

`lz-app-admin` chỉ ở **Non-Production**. `lz-app-operator` chỉ ở **Production**, chỉ đọc.

Nghĩa là:

> **Không con người nào có quyền ghi lên production application. Chỉ pipeline vào được.**

Đây là mô hình đúng. Nhưng nó phải được **viết thành chính sách**, không để ngầm — vì kéo theo ba hệ quả đến rất nhanh.

### 2.1 Pipeline trở thành đường ghi duy nhất

Role OIDC của GitHub Actions ([doc 10](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md)) giờ **mạnh hơn bất kỳ permission set nào của con người ở prod**. Phải bảo vệ tương xứng:

| Yêu cầu | Vì sao |
|---|---|
| `sub` claim ghim vào **Environment**, không phải branch | Ghim branch thì ai push được branch đó là deploy được prod |
| Bắt buộc approval trên Environment prod | Chốt chặn con người duy nhất còn lại |
| Role deploy prod không được có `iam:*` | Nếu không, pipeline tự nâng quyền cho chính nó |

### 2.2 Sự cố 2 giờ sáng — `lz-app-breakglass`

Prod hỏng, pipeline cũng hỏng, `lz-app-operator` chỉ đọc được. Ai sửa?

Không thiết kế trước thì lúc sự cố người ta sẽ dùng **root account** — tệ hơn nhiều, và không có dấu vết ai làm gì.

Nên có set riêng, `scope = "none"` — **không sinh assignment nào lúc apply**:

```hcl
"lz-app-breakglass" = {
  description      = "EMERGENCY write access to production applications"
  session_duration = "PT1H"
  scope            = "none"       # <- khong gan san
  ...
}
```

Quy trình khi cần dùng:

| Bước | Làm gì |
|---|---|
| 1 | Tạo assignment `lz-app-breakglass` → group trực → account prod cụ thể |
| 2 | EventBridge bắt `CreateAccountAssignment` → báo Slack + email |
| 3 | Xử lý sự cố, phiên tối đa 1 tiếng |
| 4 | Gỡ assignment. Nên để job hẹn giờ tự gỡ sau 4 tiếng thay vì tin vào trí nhớ |
| 5 | Ghi biên bản: ai, khi nào, vì sao, đã làm gì |

Bước 4 là bước hay hỏng nhất. Quyền khẩn cấp không tự hết hạn thì sau ba lần sự cố nó thành quyền thường trực.

### 2.3 Read-only ở prod thiếu ba thứ app team thật sự cần

| Cần làm ở prod | Read-only cho không? | Xử lý |
|---|---|---|
| **Đọc log** | **Không** — `ViewOnlyAccess` chỉ thấy log group tồn tại, không đọc được nội dung | Cấp riêng, xem dưới |
| Restart service, scale ASG | Không | SSM Automation document |
| Redrive DLQ | Không | SSM Automation document |

Đọc log là **thứ số một** app team cần ở prod và là thứ dễ sót nhất khi siết quyền. Code cấp riêng một statement:

```hcl
allow_logs_read = jsonencode({
  Sid    = "ReadApplicationLogs"
  Effect = "Allow"
  Action = [
    "logs:FilterLogEvents", "logs:GetLogEvents",
    "logs:StartQuery", "logs:StopQuery", "logs:GetQueryResults",
    ...
  ]
  Resource = "*"
})
```

Hai việc còn lại **không** cấp quyền thô. Gói vào SSM Automation document: người chạy được document nhưng không có quyền gốc, và mọi lần chạy đều có dấu vết.

> **Đánh đổi phải biết:** cho đọc log đầy đủ nghĩa là ai đọc được log cũng đọc được thứ nằm trong log. Nếu ứng dụng lỡ ghi token hay dữ liệu cá nhân ra log thì đây là đường rò. Xử lý ở **tầng ghi log**, không xử lý được ở tầng IAM.

---

## 3. Ba đường leo thang quyền

### 3.1 `ReadOnlyAccess` không phải "chỉ đọc cấu hình"

Đây là hiểu nhầm phổ biến nhất về quyền read-only trên AWS.

| Policy | Cho phép | Đọc được dữ liệu? |
|---|---|---|
| `ReadOnlyAccess` | List + Describe + **Get** | **Có** |
| `ViewOnlyAccess` | List + Describe | Không |

`ReadOnlyAccess` bao gồm `s3:GetObject`, `dynamodb:GetItem`/`Query`/`Scan`, `ssm:GetParameter`, `lambda:GetFunction` (trả về pre-signed URL tải được cả source). Gán cho auditor ở **tất cả** account nghĩa là vừa cấp quyền đọc mọi object S3 và mọi row DynamoDB của production.

"Auditor" thường được hiểu là người kiểm tra **cấu hình**, không phải người được đọc **nội dung**.

Nên bảng này dùng `ViewOnlyAccess` + `SecurityAudit`, cộng thêm một statement Deny cho chắc:

```hcl
deny_data_plane = {
  Effect = "Deny"
  Action = [
    "s3:GetObject", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
    "secretsmanager:GetSecretValue", "ssm:GetParameter",
    "kms:Decrypt", "lambda:GetFunction",
    "athena:GetQueryResults", "sqs:ReceiveMessage",
  ]
  Resource = "*"
}
```

Nhớ: **Deny tường minh luôn thắng Allow**, bất kể thứ tự hay độ cụ thể. Đây là chặn tuyệt đối, không mở lại được bằng một Allow ở chỗ khác.

Muốn auditor đọc được dữ liệu thì đặt `operator_can_read_data = true`, nhưng nên tách hẳn thành set riêng gán có thời hạn thay vì mở cho cả 8 set operator.

> `logs:*` **không** nằm trong danh sách chặn — xem mục 2.3.

### 3.2 `lz-security-admin` về kỹ thuật bằng `lz-account-admin`

Mô tả có **IAM** trong danh sách. Ai có IAM full quyền thì làm được:

```bash
aws iam create-role --role-name tmp --assume-role-policy-document ...
aws iam attach-role-policy --role-name tmp \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
aws sts assume-role --role-arn arn:aws:iam::...:role/tmp
```

Ba lệnh, từ security-admin lên full admin. Bảng thực tế chỉ có **một** mức cao nhất, không phải hai.

**Cách A — chấp nhận, ghi rõ.** Mặc định của code (`enforce_security_admin_boundary = false`). Với lab thì hợp lý. Nhưng phải ghi vào tài liệu vận hành để không ai tưởng đã tách quyền.

**Cách B — chặn thật bằng permissions boundary.**

```hcl
{
  Effect   = "Deny"
  Action   = ["iam:CreateRole", "iam:CreateUser"]
  Resource = "*"
  Condition = {
    ArnNotLike = {
      "iam:PermissionsBoundary" = "arn:aws:iam::*:policy/lz-boundary"
    }
  }
}
```

> **Chi tiết cú pháp dễ sai:** phải dùng `ArnNotLike`, **không** phải `StringNotEquals`. `StringNotEquals` so sánh chính xác, không hiểu dấu `*` trong ARN — điều kiện sẽ không bao giờ khớp và statement thành vô dụng mà không báo lỗi gì.

Kèm theo phải chặn chính policy boundary khỏi bị sửa/xoá, nếu không họ xoá boundary rồi làm lại.

Điều kiện tiên quyết: policy `lz-boundary` phải **tồn tại trong mọi account** — triển khai bằng StackSet ([doc 06 mục 12](./06-Aws-Landing-Zone.md)). Bật `enforce_security_admin_boundary = true` trước khi StackSet chạy xong thì security-admin không tạo được gì cả.

### 3.3 `iam:PassRole` — đường leo thang xuyên suốt cả bảng

Lambda, CloudFormation, SSM, SageMaker, EMR, Glue đều **chạy bằng role được pass vào**. `PassRole` không giới hạn nghĩa là:

```
server-admin → tạo Lambda, gán execution role = một role admin có sẵn
             → invoke → chạy code với quyền admin
```

Batch permission set thứ hai thêm hai đường **trực tiếp hơn**:

| Service | Đường leo thang |
|---|---|
| **SageMaker** | Notebook instance là **shell thật**, chạy bằng execution role |
| **EMR** | Cluster launch EC2 với instance profile được pass |
| **Glue** | Glue job chạy bằng role được pass |

Chốt bằng tiền tố tên role + ràng buộc service đích:

```hcl
passrole_analytics = {
  Effect   = "Allow"
  Action   = "iam:PassRole"
  Resource = "arn:aws:iam::*:role/lz-analytics-*"
  Condition = {
    StringEquals = {
      "iam:PassedToService" = [
        "sagemaker.amazonaws.com", "glue.amazonaws.com",
        "elasticmapreduce.amazonaws.com", ...
      ]
    }
  }
}
```

Quy ước: role nào workload được phép nhận thì đặt tiền tố `lz-workload-` / `lz-analytics-`. Role admin, network, security **không** mang tiền tố đó → không pass được.

Đi kèm là `deny_iam_writes` cho mọi set không thuộc miền security — chặn `CreateRole`, `AttachRolePolicy`, `UpdateAssumeRolePolicy`… để không ai tự tạo ra role mang tiền tố hợp lệ nhưng quyền admin.

### 3.4 Lake Formation là hệ phân quyền song song với IAM

Đây là điểm ít người biết nhất trong cả bảng.

```
lakeformation:PutDataLakeSettings
  → tự đặt mình làm Data Lake Administrator
  → GrantPermissions cho chính mình trên MỌI bảng Glue catalog
  → đọc toàn bộ data lake, bỏ qua bucket policy của S3
```

Nghĩa là `lakeformation:*` ≈ **quyền đọc toàn bộ dữ liệu**, bất kể bạn siết S3 thế nào.

Nên tách: `lz-analytics-admin` bị Deny bốn action cấp quyền, còn `lz-datalake-admin` (set #16) giữ chúng và cấp cho rất ít người.

```hcl
deny_lakeformation_grants = {
  Effect = "Deny"
  Action = [
    "lakeformation:PutDataLakeSettings",
    "lakeformation:GrantPermissions",
    "lakeformation:BatchGrantPermissions",
    "lakeformation:RegisterResource",
  ]
  Resource = "*"
}
```

Analytics admin bình thường dựng job và query. Việc **cấp quyền dữ liệu cho người khác** là hành vi khác hẳn, thuộc về set khác.

---

## 4. Chồng lấn và chủ sở hữu

### 4.1 `lz-app-admin` là bản sao ghép của hai set khác

Đối chiếu từng service trong bảng gốc:

```
lz-server-admin : EC2(-net,-sec) ASG ELB EBS EFS S3 Lambda SSM SNS SQS Kinesis APIGW CFN
lz-db-admin     :                                                                        RDS DynamoDB Redshift ElastiCache
                  ────────────────────────────────────────────────────────────────────────────────────────────────────────
lz-app-admin    : EC2(-net,-sec) ASG ELB EBS EFS S3 Lambda SSM SNS SQS Kinesis APIGW CFN  RDS DynamoDB Redshift ElastiCache
```

`lz-app-admin` = `lz-server-admin` ∪ `lz-db-admin`, **không lệch một service nào**. Khác biệt duy nhất là phạm vi gán.

Thiết kế hợp lý, nhưng viết tay ba lần thì sẽ trôi:

> Sáu tháng nữa thêm Step Functions vào `lz-server-admin` và quên `lz-app-admin`. Hai set lệch nhau, không ai phát hiện cho tới khi có người báo lỗi permission.

Giải bằng cách khai **một lần** trong `locals-services.tf`:

```hcl
locals {
  svc_compute  = ["autoscaling", "elasticloadbalancing", "s3", "lambda", ...]
  svc_database = ["rds", "dynamodb", "redshift", "elasticache", ...]

  actions_app_admin = sort(distinct(concat(
    ["ec2:*"],
    local.admin_actions["compute"],
    local.admin_actions["database"],
  )))
}
```

Bất biến `app_admin == server_admin ∪ db_admin` giờ **đúng theo cấu trúc**, không phải nhờ kỷ luật con người. Sửa một chỗ, ba set cập nhật.

### 4.2 Redshift có hai chủ

Xuất hiện ở cả `lz-db-*` và `lz-analytics-*` — hai team cùng admin một cluster.

Hai lựa chọn:

| Cách | Đánh đổi |
|---|---|
| Redshift thuộc **analytics**, bỏ khỏi db-admin | Rõ ràng hơn — Redshift là data warehouse, không phải OLTP database |
| Giữ cả hai | Linh hoạt, nhưng phải ghi rõ là **cố ý** để lần sau không ai "dọn dẹp" nhầm |

Code hiện giữ cả hai và ghi chú ngay tại chỗ. Đổi thì sửa `svc_database` trong `locals-services.tf`.

S3 và Lambda cũng có ba chủ (`server`, `app`, `analytics`). S3 ít rủi ro hơn; Lambda đáng chú ý hơn vì nó là đường PassRole.

### 4.3 `lz-db-admin` ở "All" ngược với chính sách prod

Bảng khoá app team khỏi prod, nhưng `lz-db-admin` gán All account → **có toàn quyền ghi lên database production**. Và `dynamodb:Scan` = đọc được toàn bộ dữ liệu khách hàng.

Đây là quyền **có giá trị cao nhất trong cả 17 set** — xét về rủi ro dữ liệu thì cao hơn `lz-account-admin`, vì admin hạ tầng ít khi cần đọc từng row.

Không nhất thiết sai — DBA thật sự cần. Nhưng phải là quyết định **có ý thức**, kèm:

- `session_duration = "PT1H"` (đã đặt trong code)
- CloudTrail alert cho `dynamodb:Scan` và `rds:*Snapshot*` trên account prod
- Cân nhắc tách `lz-db-admin-prod` gán riêng thay vì gộp vào "All"

---

## 5. Service thiếu trong bảng gốc

Rà 15 set gốc, những thứ sau không xuất hiện ở đâu cả:

| Thiếu | Ai cần | Hậu quả nếu thiếu | Đã thêm vào |
|---|---|---|---|
| `network-firewall:*` | network-admin | **Không dựng nổi security VPC của doc 15** | `svc_network` |
| `route53resolver:*` | network-admin | Không tạo được resolver endpoint (doc 12) | `svc_network` |
| `ram:*` | network-admin | Không share được TGW cross-account (doc 13) | `svc_network` |
| `states`, `events`, `scheduler` | app team | Lõi của doc 01–05 trong chính repo này | `svc_compute` |
| `ecr`, `ecs`, `eks` | app team | Không push nổi image cho Lambda container | `svc_compute` |
| `secretsmanager` | app team | Sẽ có người nhét secret vào biến môi trường | `svc_compute` |
| `logs`, `cloudwatch`, `xray` | mọi người | Không đọc được log của chính mình | `svc_compute` |

Ba dòng đầu quan trọng nhất: mô tả gốc ghi "EC2 network APIs, Direct Connect, Route 53", nhưng ba service này nằm ở **namespace API khác hẳn** — `network-firewall:*` không thuộc `ec2:*`, và `route53resolver:*` không thuộc `route53:*`.

---

## 6. Hạn chế kỹ thuật: không gán được cho OU

Cột "AWS Account" có 5 giá trị, rất tự nhiên khi nghĩ "gán `lz-app-admin` cho OU Non-Production". Nhưng:

> **Identity Center không gán assignment cho OU.** `target_type` chỉ nhận `AWS_ACCOUNT`. Phải liệt kê từng account ID.

Nên `organizations.tf` suy phạm vi `all` từ Organizations, còn bốn phạm vi kia khai qua biến:

```hcl
data "aws_organizations_organization" "this" {}

locals {
  active_accounts = [
    for a in data.aws_organizations_organization.this.accounts :
    a.id if a.status == "ACTIVE"     # account SUSPENDED se lam assignment loi
  ]
}
```

**Hệ quả vận hành quan trọng nhất của cả tài liệu này:**

> Tạo account mới trong OU non-prod mà không chạy lại `terraform apply` thì **không ai vào được account đó** — và người ta sẽ quay ra dùng root.

Phải gắn bước này vào account vending ([doc 09](./09-Account-Vending-Tu-Dong.md)). Output `unscoped_accounts` liệt kê đúng những account đang bị bỏ quên:

```bash
terraform output unscoped_accounts
```

---

## 7. Rà chéo với SCP

Permission set cho phép **≠** làm được. Một action chạy được chỉ khi **cả** permission set **lẫn** SCP cho phép.

Đối chiếu với `deny-internet-paths.json` ([doc 13](./13-Centralized-Ingress-Egress-Network.md)):

| Action | SCP (account ≠ network) | Permission set | Kết quả |
|---|---|---|---|
| `ec2:CreateInternetGateway` | Deny | `lz-network-admin` Allow | **Bị chặn** — đúng thiết kế |
| `ec2:CreateNatGateway` | Deny | `lz-network-admin` Allow | **Bị chặn** — đúng thiết kế |
| `ec2:AllocateAddress` | Deny | `lz-network-admin` Allow | **Bị chặn** — đúng thiết kế |
| `ec2:CreateTransitGateway` | Deny | `lz-network-admin` Allow | **Bị chặn** — chỉ tạo ở network account |
| `ec2:RunInstances` + public IP | Deny | `lz-app-admin` Allow | **Bị chặn** |
| `ec2:RunInstances` subnet private | Cho | `lz-app-admin` Allow | Chạy được |
| `ec2:CreateInternetGateway` | Deny | `lz-app-admin` **cũng Deny** | Chặn hai lớp |

Không có mâu thuẫn nào. Hai chỗ đáng ghi nhớ:

**1. `lz-network-admin` ở account app-prod sẽ không tạo được IGW dù permission set cho phép.** Đây là **đúng**, không phải bug. Ghi vào tài liệu vận hành, nếu không sẽ có người mở ticket.

**2. `deny_ec2_network` trong `lz-server-admin`/`lz-app-admin` trùng lặp với SCP một cách có chủ ý.** SCP là tầng bảo vệ của tổ chức, Deny trong permission set là tầng bảo vệ của vai trò. Trùng nhau là tốt — một tầng hỏng thì tầng kia còn.

Nhắc lại: **SCP không áp dụng cho management account.** Đó là lý do `exclude_management_from_all = true` — mọi quyền cấp ở management account là quyền thật, không có trần chặn.

---

## 8. Thời lượng phiên và MFA

### 8.1 Phân tầng theo rủi ro

| Phiên | Set | Vì sao |
|---|---|---|
| **1 giờ** | account-admin, security-admin, db-admin, datalake-admin, breakglass | Quyền ghi cao hoặc chạm dữ liệu production |
| **4 giờ** | network-admin, server-admin, app-admin, analytics-admin, billing | Quyền ghi thường ngày |
| **8 giờ** | mọi set operator, auditor | Chỉ đọc, rủi ro thấp, đừng bắt đăng nhập lại cả ngày |

### 8.2 Đừng đặt điều kiện MFA trong policy

> **Không** dùng `aws:MultiFactorAuthPresent` trong policy của permission set.

Phiên Identity Center không mang claim này một cách đáng tin. Thêm vào sẽ sinh Access Denied khó hiểu, và người ta sẽ đi tìm lỗi ở chỗ khác.

MFA phải ép ở **đúng tầng của nó**: Identity Center console → Settings → Authentication → *Require MFA every time*. Đây là bước thủ công, Terraform không làm được.

### 8.3 Công tắc thủ công cho billing

`lz-billing` cần bật riêng ở management account:

```
Billing console → Account → IAM user and role access to Billing information → Activate
```

Không bật thì permission set có `Billing` policy vẫn nhận Access Denied. Đây là bước hay mất nửa buổi để tìm ra.

> Ghi chú: `aws-portal:*` đã bị AWS ngừng (2023) và thay bằng các namespace riêng — `billing`, `payments`, `tax`, `consolidatedbilling`, `invoicing`, `purchase-orders`, `freetier`. Policy cũ chỉ có `aws-portal:*` không còn tác dụng đầy đủ. Code đã dùng bộ mới.

---

## 9. Kiểm chứng

### 9.1 Trước khi apply

```bash
cd landing-zone/permission-sets
terraform init
./validate-policies.sh
```

Script kiểm tra từng inline policy: JSON hợp lệ, không lọt giá trị `null`, mọi statement có `Effect`, và kích thước dưới giới hạn.

Vì sao cần: `permission-sets.tf` ráp policy bằng `join()` chuỗi thay vì `jsonencode` cả list — Terraform không ghép được list các object có bộ thuộc tính khác nhau (có `Condition` / không có `Condition`), `concat()` và `for` sẽ ép kiểu rồi báo lỗi. Đánh đổi là trình biên dịch không còn bắt lỗi JSON hộ mình nữa, nên phải có script.

Kết quả trên bộ code hiện tại: **17/17 hợp lệ**, lớn nhất 3.072 bytes (`lz-app-operator`), giới hạn 32.768.

### 9.2 Sau khi apply

```bash
terraform output assignment_matrix   # doi chieu voi bang thiet ke
terraform output unscoped_accounts   # account quen khai pham vi
terraform output accounts_in_scope
```

Đăng nhập thử:

```bash
aws sso login --profile lz-network
aws sts get-caller-identity --profile lz-network
```

ARN phải có dạng `assumed-role/AWSReservedSSO_lz-network-admin_<hash>/<user>`.

### 9.3 Kiểm chứng phần chặn — quan trọng hơn kiểm chứng phần cho

Cấp quyền đúng thì người dùng tự báo. Chặn sai thì **im lặng** cho tới khi có sự cố. Nên phải chủ động thử:

```bash
# Auditor KHONG duoc doc du lieu
aws s3 cp s3://<bucket-prod>/<key> - --profile lz-auditor
# ky vong: AccessDenied

# Server-admin KHONG duoc tao Internet Gateway
aws ec2 create-internet-gateway --profile lz-server-admin
# ky vong: AccessDenied (ca deny_ec2_network lan SCP)

# Server-admin KHONG duoc pass role admin
aws lambda create-function --role arn:aws:iam::<acct>:role/lz-account-admin-role \
  --function-name t --runtime python3.12 --handler i.h --zip-file fileb://f.zip \
  --profile lz-server-admin
# ky vong: AccessDenied tren iam:PassRole

# App-operator KHONG duoc ghi o prod
aws lambda update-function-code --function-name <fn> --zip-file fileb://f.zip \
  --profile lz-app-prod
# ky vong: AccessDenied

# App-operator PHAI doc duoc log
aws logs filter-log-events --log-group-name /aws/lambda/<fn> --profile lz-app-prod
# ky vong: THANH CONG
```

Dòng cuối quan trọng ngang những dòng trên: siết quá tay cũng là lỗi.

---

## 10. Sổ quyết định

| # | Quyết định | Lý do | Đánh đổi |
|---|---|---|---|
| D1 | `lz-auditor` dùng `ViewOnlyAccess`, không `ReadOnlyAccess` | `ReadOnlyAccess` đọc được cả dữ liệu | Auditor cần xem nội dung phải xin quyền riêng |
| D2 | Thêm `deny_data_plane` cho mọi set operator | Chặn hai lớp, phòng managed policy đổi nội dung | Có thể chặn nhầm ca hợp lệ → có biến để tắt |
| D3 | `logs:*` **không** nằm trong deny list | App team phải đọc được log ở prod | Log chứa dữ liệu nhạy cảm thì rò — xử lý ở tầng ghi log |
| D4 | Chốt `PassRole` theo tiền tố role | Đường leo thang lớn nhất của cả bảng | Phải đặt tên role theo quy ước, quên là lỗi khó hiểu |
| D5 | Boundary cho security-admin mặc định **tắt** | Cần StackSet đẩy policy xuống mọi account trước | Trong lúc đó security-admin ≡ account-admin |
| D6 | Tách `lz-datalake-admin` | `lakeformation:*` bỏ qua được cả bucket policy S3 | Thêm một set phải quản |
| D7 | Thêm `lz-app-breakglass`, không gán sẵn | Prod không ai ghi được, phải có đường vào lúc sự cố | Chưa tự động hoá việc gỡ assignment |
| D8 | Danh sách service khai một lần trong locals | `app = server ∪ db` phải đúng theo cấu trúc | Đọc code khó hơn viết tay từng set |
| D9 | Ráp policy bằng chuỗi JSON | Terraform không ghép được list object khác bộ thuộc tính | Mất kiểm tra kiểu → bù bằng `validate-policies.sh` |
| D10 | Giữ Redshift ở cả db và analytics | Hai team đều có nhu cầu thật | Chồng chủ sở hữu — ghi rõ là cố ý |
| D11 | Loại management account khỏi phạm vi "all" | SCP không áp dụng cho management account | Vào management phải qua `lz-account-admin` gán riêng |
| D12 | Session 1h/4h/8h theo rủi ro | Admin bị lộ session nguy hiểm hơn operator | Admin phải đăng nhập lại thường xuyên hơn |

---

## 11. Việc còn lại

| # | Việc | Chặn bởi |
|---|---|---|
| 1 | Chạy `terraform init && plan` ở môi trường có registry | Môi trường soạn tài liệu chặn `registry.terraform.io` |
| 2 | StackSet đẩy policy `lz-boundary` xuống mọi account, rồi bật `enforce_security_admin_boundary` | Cần doc 06 mục 12 chạy trước |
| 3 | Tự động hoá break-glass: tạo assignment + EventBridge alert + job tự gỡ | — |
| 4 | CloudTrail alert cho `dynamodb:Scan`, `rds:*Snapshot*` ở account prod | — |
| 5 | Bộ SSM Automation document cho thao tác vận hành prod (restart, scale, redrive DLQ) | — |
| 6 | Gắn bước cập nhật `accounts_by_scope` vào account vending | doc 09 |
| 7 | Chốt: Redshift một chủ hay hai chủ | Quyết định của bạn |
| 8 | Chốt: `lz-db-admin` có tách riêng cho prod không | Quyết định của bạn |

---

## Liên quan

| Tài liệu | Quan hệ |
|---|---|
| [06 – AWS Landing Zone](./06-Aws-Landing-Zone.md) | Organizations, OU, SCP, bật Identity Center |
| [08 – Đồng bộ user AD](./08-Dong-bo-User-AD-sang-IAM-Identity-Center.md) | Khi có AD/IdP ngoài — SCIM làm chủ, Terraform chỉ đọc |
| [09 – Account vending](./09-Account-Vending-Tu-Dong.md) | Account mới phải cập nhật `accounts_by_scope` |
| [10 – CI/CD GitHub Actions OIDC](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) | Đường ghi duy nhất vào prod — bảo vệ tương xứng |
| [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) | SCP `deny-internet-paths` — rà chéo ở mục 7 |
| [17 – Network LZ Design Guide](./17-Network-LZ-Design-Guide.md) | Thiết kế mạng tổng thể |
