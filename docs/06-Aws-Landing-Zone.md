# AWS Landing Zone – Multi-account Foundation (Organizations + SCP + Identity Center + Logging + Network)

Ví dụ 06: Dựng **Landing Zone (LZ)** – phần nền tảng multi-account bạn làm **một lần** trước khi deploy các workload (như ví dụ 01–05) lên trên.

Stack trong bài:

- **AWS Organizations** (OU + member accounts)
- **Service Control Policies (SCP)** – guardrails
- **AWS IAM Identity Center** (SSO) – login tập trung, không dùng IAM user
- **Centralized logging** – Organization CloudTrail + AWS Config aggregator → account Log Archive
- **Security tooling** – GuardDuty + Security Hub delegated admin
- **Network baseline** – Transit Gateway hub, centralized egress, RAM share
- **Account baseline** – những thứ bật mặc định cho mọi account mới
- IaC với **Terraform**

> Lưu ý: LZ đụng tới billing, IAM và Organizations của toàn bộ tổ chức. Chạy thử ở một AWS Organization sandbox trước, đừng apply thẳng vào org production.

---

## 1. Landing Zone là gì và khi nào cần

Landing Zone = bộ khung multi-account đã được cấu hình sẵn về **identity, security, logging, network và billing**, để mỗi khi có team/dự án mới thì chỉ cần "phát" cho họ một account đã đạt chuẩn, thay vì dựng lại từ đầu.

Khi nào nên làm:

- Đã có > 2–3 account và bắt đầu loạn quyền / loạn chi phí.
- Cần tách môi trường **dev / staging / prod** ở mức account (blast radius rõ ràng, quota riêng).
- Cần audit log không bị chính người gây lỗi xoá.
- Cần trả lời được: "ai đang có quyền gì ở account nào".

Nguyên tắc thiết kế xuyên suốt:

| Nguyên tắc | Cách thể hiện trong LZ |
|---|---|
| Account là boundary bảo mật | Mỗi env / mỗi domain một account riêng |
| Guardrail thay vì review thủ công | SCP chặn ở mức OU, không dựa vào con người nhớ |
| Log bất biến, tập trung | Org CloudTrail ghi thẳng sang account Log Archive |
| Không có IAM user dài hạn | Login qua Identity Center, credential ngắn hạn |
| Management account "sạch" | Chỉ chứa Organizations + billing, không chạy workload |

---

## 2. Kiến trúc tổng quan

```text
                    ┌──────────────────────────────┐
                    │   Management Account (root)  │
                    │  Organizations, Billing, SCP │
                    │  IAM Identity Center         │
                    └──────────────┬───────────────┘
                                   │
      ┌──────────────┬─────────────┼──────────────┬────────────────┐
      │              │             │              │                │
 ┌────▼────┐   ┌─────▼─────┐  ┌────▼─────┐  ┌─────▼──────┐  ┌──────▼──────┐
 │ OU:     │   │ OU:       │  │ OU:      │  │ OU:        │  │ OU:         │
 │ Security│   │ Infra     │  │ Workloads│  │ Workloads  │  │ Sandbox     │
 │         │   │           │  │ /NonProd │  │ /Prod      │  │             │
 ├─────────┤   ├───────────┤  ├──────────┤  ├────────────┤  ├─────────────┤
 │ log-    │   │ network   │  │ app-dev  │  │ app-prod   │  │ sandbox-*   │
 │ archive │   │ (TGW,     │  │ app-stg  │  │            │  │             │
 │ security│   │  egress)  │  │          │  │            │  │             │
 └─────────┘   └───────────┘  └──────────┘  └────────────┘  └─────────────┘
```

Luồng dữ liệu chính:

1. **Log**: mọi account → Organization CloudTrail → S3 bucket ở `log-archive`.
2. **Config**: mọi account bật Config recorder → aggregator ở `security`.
3. **Findings**: GuardDuty + Security Hub delegated admin ở `security`, auto-enable cho member mới.
4. **Network**: spoke VPC ở account workload → attach vào Transit Gateway ở `network` → egress ra Internet qua NAT tập trung.
5. **Identity**: user login Identity Center → assume Permission Set → vào account tương ứng.

Vai trò từng account:

| Account | Nhiệm vụ | Ai được vào |
|---|---|---|
| `management` | Organizations, SCP, billing, Identity Center | Chỉ admin nền tảng, dùng rất ít |
| `log-archive` | Chứa S3 log bất biến (CloudTrail, Config, VPC Flow Logs) | Read-only cho auditor |
| `security` | GuardDuty/Security Hub admin, Config aggregator | Security team |
| `network` | TGW, centralized egress, DNS, (tuỳ chọn) Network Firewall | Network team |
| `app-dev/stg/prod` | Workload thật (chỗ deploy ví dụ 01–05) | Dev team qua Permission Set |
| `sandbox-*` | Nghịch tự do, có budget cap | Ai cũng được, SCP siết chặt |

---

## 3. Control Tower hay tự build bằng Terraform?

Hai đường, chọn theo team:

| Tiêu chí | AWS Control Tower | Tự build Terraform (bài này) |
|---|---|---|
| Thời gian dựng ban đầu | ~1–2 giờ, click console | ~1–2 tuần làm cho chuẩn |
| Guardrail có sẵn | Nhiều, quản lý qua console | Tự viết SCP, tự chọn |
| Tạo account mới | Account Factory / AFT | `aws_organizations_account` + module baseline |
| Mức kiểm soát | Bị giới hạn theo khuôn AWS | Toàn quyền |
| Drift / gỡ bỏ | Khó gỡ, hay bị "drift detected" | Chỉ là Terraform, dễ đổi |
| Chi phí | Không tính phí Control Tower, chỉ trả cho service bên dưới | Tương tự |

Gợi ý thực tế:

- Team nhỏ, chưa có người chuyên platform → **Control Tower** rồi mở rộng bằng Terraform sau.
- Team đã quen Terraform, cần custom nhiều (multi-region, network riêng) → **tự build** như dưới đây.

Nếu muốn Control Tower nhưng vẫn quản bằng code, có resource:

```hcl
resource "aws_controltower_landing_zone" "this" {
  manifest_json = file("${path.module}/manifest.json")
  version       = "3.3"
}
```

và dùng **AFT (Account Factory for Terraform)** để vending account. Phần còn lại của bài đi theo hướng tự build.

---

## 4. Cấu trúc thư mục

```text
aws-landing-zone/
  0-bootstrap/            # tạo S3 backend + DynamoDB lock cho state
    main.tf
  1-organization/         # OU, accounts, SCP
    main.tf
    scp.tf
    policies/
      deny-region.json
      deny-leave-org.json
      protect-security-services.json
      sandbox-restrictions.json
  2-logging/              # org CloudTrail + S3 ở log-archive
    main.tf
  3-security/             # GuardDuty, Security Hub, Config aggregator
    main.tf
  4-identity-center/      # permission sets + assignments
    main.tf
  5-network/              # TGW, RAM share, centralized egress
    main.tf
  modules/
    account-baseline/     # apply cho MỌI account
      main.tf
      variables.tf
    spoke-vpc/
      main.tf
```

Thứ tự apply: `0 → 1 → 2 → 3 → 4 → 5`. Mỗi thư mục là một state riêng để lỡ hỏng thì không kéo sập cả LZ.

---

## 5. Bootstrap – nơi để state

Chạy ở **management account**, bằng credential admin (lần duy nhất dùng access key thủ công).

### 5.1. 0-bootstrap/main.tf

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

resource "aws_s3_bucket" "tf_state" {
  bucket = "acme-lz-tfstate-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket                  = aws_s3_bucket.tf_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = "acme-lz-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

Sau khi apply, các thư mục còn lại dùng backend:

```hcl
terraform {
  backend "s3" {
    bucket         = "acme-lz-tfstate-111111111111"
    key            = "1-organization/terraform.tfstate"
    region         = "ap-southeast-1"
    dynamodb_table = "acme-lz-tflock"
    encrypt        = true
  }
}
```

---

## 6. Organization – OU và accounts

### 6.1. 1-organization/main.tf

```hcl
provider "aws" {
  region = "ap-southeast-1"
}

########################
# Organization
########################

resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "sso.amazonaws.com",
    "ram.amazonaws.com",
    "account.amazonaws.com",
  ]

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
  ]
}

########################
# Organizational Units
########################

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads_nonprod" {
  name      = "NonProd"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "workloads_prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = aws_organizations_organization.this.roots[0].id
}

########################
# Member accounts
########################

locals {
  # email phải unique toàn AWS. Dùng plus-addressing cho gọn:
  # aws+log-archive@acme.com, aws+security@acme.com, ...
  email_domain = "acme.com"
}

resource "aws_organizations_account" "log_archive" {
  name              = "acme-log-archive"
  email             = "aws+log-archive@${local.email_domain}"
  parent_id         = aws_organizations_organizational_unit.security.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "security" {
  name              = "acme-security"
  email             = "aws+security@${local.email_domain}"
  parent_id         = aws_organizations_organizational_unit.security.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "network" {
  name              = "acme-network"
  email             = "aws+network@${local.email_domain}"
  parent_id         = aws_organizations_organizational_unit.infrastructure.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "app_dev" {
  name              = "acme-app-dev"
  email             = "aws+app-dev@${local.email_domain}"
  parent_id         = aws_organizations_organizational_unit.workloads_nonprod.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "app_prod" {
  name              = "acme-app-prod"
  email             = "aws+app-prod@${local.email_domain}"
  parent_id         = aws_organizations_organizational_unit.workloads_prod.id
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false

  lifecycle {
    ignore_changes = [role_name]
  }
}

########################
# Delegated administrators
########################

resource "aws_organizations_delegated_administrator" "config" {
  account_id        = aws_organizations_account.security.id
  service_principal = "config.amazonaws.com"
}

output "account_ids" {
  value = {
    log_archive = aws_organizations_account.log_archive.id
    security    = aws_organizations_account.security.id
    network     = aws_organizations_account.network.id
    app_dev     = aws_organizations_account.app_dev.id
    app_prod    = aws_organizations_account.app_prod.id
  }
}
```

Vài chỗ dễ vấp:

- `email` phải **chưa từng dùng** cho AWS account nào. Dùng `aws+xxx@domain` và trỏ về một mailing list, đừng dùng email cá nhân.
- `role_name = "OrganizationAccountAccessRole"` là cách bạn vào account con sau này (assume role từ management). Đặt `ignore_changes` vì AWS không cho sửa sau khi tạo.
- Xoá `aws_organizations_account` khỏi Terraform **không** đóng account, chỉ tách khỏi org. `close_on_deletion = false` để tránh tai nạn.

### 6.2. Assume role vào account con

Các thư mục sau (`2-logging`, `3-security`, …) khai báo provider alias:

```hcl
provider "aws" {
  alias  = "log_archive"
  region = "ap-southeast-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
  }
}

provider "aws" {
  alias  = "security"
  region = "ap-southeast-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.security_account_id}:role/OrganizationAccountAccessRole"
  }
}
```

---

## 7. SCP – guardrails

SCP là **giới hạn trần quyền**, không cấp quyền. Một action chỉ chạy được khi **cả** IAM policy lẫn SCP cho phép. SCP không áp dụng cho management account – đó là lý do management account phải "sạch".

### 7.1. policies/deny-region.json

Chỉ cho dùng 2 region, trừ các global service.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyUnapprovedRegions",
      "Effect": "Deny",
      "NotAction": [
        "iam:*",
        "organizations:*",
        "sts:*",
        "cloudfront:*",
        "route53:*",
        "support:*",
        "budgets:*",
        "waf:*",
        "health:*"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestedRegion": [
            "ap-southeast-1",
            "us-east-1"
          ]
        }
      }
    }
  ]
}
```

### 7.2. policies/deny-leave-org.json

Chặn account con tự tách khỏi org và chặn xoá vai trò nền tảng.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyLeaveOrganization",
      "Effect": "Deny",
      "Action": [
        "organizations:LeaveOrganization"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProtectOrgRoles",
      "Effect": "Deny",
      "Action": [
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:AttachRolePolicy",
        "iam:PutRolePolicy",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource": [
        "arn:aws:iam::*:role/OrganizationAccountAccessRole",
        "arn:aws:iam::*:role/aws-service-role/*",
        "arn:aws:iam::*:role/AcmeAccountBaseline*"
      ]
    },
    {
      "Sid": "DenyRootUserActions",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:PrincipalArn": "arn:aws:iam::*:root"
        }
      }
    }
  ]
}
```

### 7.3. policies/protect-security-services.json

Không cho tắt log/security tooling. Đây là SCP có giá trị nhất trong cả bộ.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ProtectCloudTrail",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
        "cloudtrail:PutEventSelectors"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProtectConfig",
      "Effect": "Deny",
      "Action": [
        "config:DeleteConfigurationRecorder",
        "config:StopConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:DeleteConfigRule",
        "config:DeleteOrganizationConfigRule"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ProtectGuardDutyAndSecurityHub",
      "Effect": "Deny",
      "Action": [
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromMasterAccount",
        "guardduty:UpdateDetector",
        "securityhub:DisableSecurityHub",
        "securityhub:DisassociateFromMasterAccount",
        "securityhub:DeleteMembers"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyPublicS3",
      "Effect": "Deny",
      "Action": [
        "s3:PutAccountPublicAccessBlock",
        "s3:DeleteAccountPublicAccessBlock"
      ],
      "Resource": "*"
    }
  ]
}
```

### 7.4. policies/sandbox-restrictions.json

OU Sandbox: cho nghịch nhưng không cho đốt tiền.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyExpensiveInstances",
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances"
      ],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringNotLike": {
          "ec2:InstanceType": [
            "t3.*",
            "t4g.*"
          ]
        }
      }
    },
    {
      "Sid": "DenyExpensiveServices",
      "Effect": "Deny",
      "Action": [
        "redshift:CreateCluster",
        "sagemaker:CreateEndpoint",
        "sagemaker:CreateNotebookInstance",
        "elasticmapreduce:RunJobFlow",
        "directconnect:*"
      ],
      "Resource": "*"
    }
  ]
}
```

### 7.5. 1-organization/scp.tf

```hcl
locals {
  scps = {
    deny_region        = "policies/deny-region.json"
    deny_leave_org     = "policies/deny-leave-org.json"
    protect_security   = "policies/protect-security-services.json"
    sandbox_restrict   = "policies/sandbox-restrictions.json"
  }
}

resource "aws_organizations_policy" "scp" {
  for_each = local.scps

  name    = replace(each.key, "_", "-")
  type    = "SERVICE_CONTROL_POLICY"
  content = file("${path.module}/${each.value}")
}

# Áp cho toàn org (trừ management account – SCP không ảnh hưởng account này)
resource "aws_organizations_policy_attachment" "root_baseline" {
  for_each = toset(["deny_region", "deny_leave_org", "protect_security"])

  policy_id = aws_organizations_policy.scp[each.value].id
  target_id = aws_organizations_organization.this.roots[0].id
}

# Riêng OU Sandbox
resource "aws_organizations_policy_attachment" "sandbox" {
  policy_id = aws_organizations_policy.scp["sandbox_restrict"].id
  target_id = aws_organizations_organizational_unit.sandbox.id
}
```

Cách roll out an toàn: attach vào **OU Sandbox trước**, sống với nó 1–2 tuần, rồi mới lên NonProd, cuối cùng là root. Attach nhầm SCP vào root có thể làm cả tổ chức không deploy được.

---

## 8. Centralized logging – Organization CloudTrail

Bucket nằm ở `log-archive`, trail tạo ở `management` với `is_organization_trail = true` → mọi account trong org tự động ghi log vào đây, member account không tắt được (đã có SCP ở mục 7.3).

### 8.1. 2-logging/main.tf

```hcl
variable "log_archive_account_id" { type = string }
variable "organization_id" { type = string }

provider "aws" {
  region = "ap-southeast-1"
}

provider "aws" {
  alias  = "log_archive"
  region = "ap-southeast-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.log_archive_account_id}:role/OrganizationAccountAccessRole"
  }
}

data "aws_caller_identity" "management" {}

########################
# S3 bucket ở log-archive
########################

resource "aws_s3_bucket" "cloudtrail" {
  provider = aws.log_archive
  bucket   = "acme-org-cloudtrail-${var.log_archive_account_id}"
}

resource "aws_s3_bucket_versioning" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  provider                = aws.log_archive
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Chuyển sang Glacier sau 90 ngày, xoá sau 7 năm
resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id

  rule {
    id     = "archive-then-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 2555
    }
  }
}

# Object Lock chỉ bật được lúc TẠO bucket (object_lock_enabled = true).
# Nếu cần WORM thật sự cho auditor, tạo bucket mới với object lock ngay từ đầu.

resource "aws_s3_bucket_policy" "cloudtrail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWriteOrg"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${var.organization_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "AWSCloudTrailWriteManagement"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.management.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.cloudtrail.arn,
          "${aws_s3_bucket.cloudtrail.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

########################
# Organization trail (tạo ở management account)
########################

resource "aws_cloudtrail" "org" {
  name                          = "acme-org-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.cloudtrail.id
}
```

Muốn log cả data event của S3/Lambda (ví dụ 01–05 sinh ra nhiều), thêm:

```hcl
  advanced_event_selector {
    name = "log-s3-data-events"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }
  }
```

Cẩn thận chi phí: data event tính tiền theo số event, bật cho toàn org có thể tốn hơn management event rất nhiều.

---

## 9. Security tooling – GuardDuty, Security Hub, Config aggregator

Pattern chung: **delegate admin** từ management sang account `security`, rồi bật auto-enable cho mọi member (kể cả account tạo sau này).

### 9.1. 3-security/main.tf

```hcl
variable "security_account_id" { type = string }

provider "aws" {
  region = "ap-southeast-1"
}

provider "aws" {
  alias  = "security"
  region = "ap-southeast-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.security_account_id}:role/OrganizationAccountAccessRole"
  }
}

########################
# GuardDuty
########################

# Bước 1: management chỉ định security account làm admin
resource "aws_guardduty_organization_admin_account" "this" {
  admin_account_id = var.security_account_id
}

# Bước 2: bật detector trong security account
resource "aws_guardduty_detector" "security" {
  provider = aws.security
  enable   = true

  datasources {
    s3_logs {
      enable = true
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  depends_on = [aws_guardduty_organization_admin_account.this]
}

# Bước 3: auto-enable cho mọi member, kể cả account mới
resource "aws_guardduty_organization_configuration" "this" {
  provider                         = aws.security
  detector_id                      = aws_guardduty_detector.security.id
  auto_enable_organization_members = "ALL"

  datasources {
    s3_logs {
      auto_enable = true
    }
  }
}

########################
# Security Hub
########################

resource "aws_securityhub_organization_admin_account" "this" {
  admin_account_id = var.security_account_id
}

resource "aws_securityhub_account" "security" {
  provider                  = aws.security
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

resource "aws_securityhub_organization_configuration" "this" {
  provider    = aws.security
  auto_enable = true

  depends_on = [
    aws_securityhub_organization_admin_account.this,
    aws_securityhub_account.security,
  ]
}

# Bật standard: AWS Foundational Security Best Practices + CIS
resource "aws_securityhub_standards_subscription" "fsbp" {
  provider      = aws.security
  standards_arn = "arn:aws:securityhub:ap-southeast-1::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.security]
}

resource "aws_securityhub_standards_subscription" "cis" {
  provider      = aws.security
  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"

  depends_on = [aws_securityhub_account.security]
}

########################
# AWS Config aggregator
########################

resource "aws_iam_role" "config_aggregator" {
  provider = aws.security
  name     = "AcmeConfigAggregatorRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_aggregator" {
  provider   = aws.security
  role       = aws_iam_role.config_aggregator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

resource "aws_config_configuration_aggregator" "org" {
  provider = aws.security
  name     = "acme-org-aggregator"

  organization_aggregation_source {
    all_regions = true
    role_arn    = aws_iam_role.config_aggregator.arn
  }

  depends_on = [aws_iam_role_policy_attachment.config_aggregator]
}
```

> Security Hub bắt buộc thứ tự: `organization_admin_account` (ở management) → `securityhub_account` (ở security) → `organization_configuration`. Nếu apply một phát bị lỗi `InvalidAccessException`, chạy lại `terraform apply` lần hai là qua – service cần vài giây để propagate delegated admin.

Sau khi apply, mọi finding của mọi account đổ về một chỗ: `security` account → Security Hub console.

---

## 10. IAM Identity Center – login tập trung

Mục tiêu: **không còn IAM user nào** trong các account workload. Dev login qua SSO portal, chọn account + role, nhận credential ngắn hạn.

Identity Center phải được **enable thủ công một lần** trong console management account (Terraform không tạo được instance). Sau đó quản Permission Set bằng code.

### 10.1. 4-identity-center/main.tf

```hcl
provider "aws" {
  region = "ap-southeast-1"
}

data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

########################
# Permission Sets
########################

resource "aws_ssoadmin_permission_set" "admin" {
  name             = "AdministratorAccess"
  description      = "Full admin – chỉ dùng cho platform team"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_permission_set" "developer" {
  name             = "DeveloperAccess"
  description      = "Deploy workload, không đụng IAM/Organizations"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "developer_poweruser" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# Chặn thêm vài thứ ngay trong permission set
resource "aws_ssoadmin_permission_set_inline_policy" "developer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging",
          "cloudtrail:DeleteTrail",
          "guardduty:DeleteDetector",
          "config:DeleteConfigurationRecorder"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_ssoadmin_permission_set" "readonly" {
  name             = "ReadOnlyAccess"
  description      = "Auditor / on-call xem log"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "readonly" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.readonly.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

########################
# Groups (nếu dùng Identity Center directory)
########################

resource "aws_identitystore_group" "platform" {
  identity_store_id = local.identity_store_id
  display_name      = "platform-team"
  description       = "Platform / DevOps"
}

resource "aws_identitystore_group" "developers" {
  identity_store_id = local.identity_store_id
  display_name      = "developers"
  description       = "Application developers"
}

########################
# Assignments
########################

variable "account_ids" {
  type = map(string)
  # { app_dev = "2222...", app_prod = "3333...", ... }
}

# platform-team: admin ở mọi account
resource "aws_ssoadmin_account_assignment" "platform_admin" {
  for_each = var.account_ids

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  principal_id       = aws_identitystore_group.platform.group_id
  principal_type     = "GROUP"
  target_id          = each.value
  target_type        = "AWS_ACCOUNT"
}

# developers: full quyền ở dev, chỉ read ở prod
resource "aws_ssoadmin_account_assignment" "dev_developer" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.developer.arn
  principal_id       = aws_identitystore_group.developers.group_id
  principal_type     = "GROUP"
  target_id          = var.account_ids["app_dev"]
  target_type        = "AWS_ACCOUNT"
}

resource "aws_ssoadmin_account_assignment" "prod_readonly" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.readonly.arn
  principal_id       = aws_identitystore_group.developers.group_id
  principal_type     = "GROUP"
  target_id          = var.account_ids["app_prod"]
  target_type        = "AWS_ACCOUNT"
}
```

Dev dùng CLI:

```bash
aws configure sso
# SSO start URL: https://d-xxxxxxxxxx.awsapps.com/start
# chọn account + permission set → đặt profile name

aws sts get-caller-identity --profile app-dev
```

Nếu công ty đã có Okta / Entra ID / Google Workspace, cấu hình **external identity provider** với SCIM sync thay vì tạo group thủ công như trên. Chi tiết đồng bộ user/group từ AD on-premise: [08 – Đồng bộ user AD sang Identity Center](./08-Dong-bo-User-AD-sang-IAM-Identity-Center.md).

### Ba permission set ở trên chỉ là ví dụ tối thiểu

Đủ để bắt đầu, nhưng thiếu hai thứ khi LZ lớn lên:

**1. Chưa có phần tạo user.** Đoạn code trên chỉ có group. Nếu bạn **không có AD và không có IdP ngoài** thì identity source là Identity Center directory, và Terraform tạo user được luôn:

```hcl
resource "aws_identitystore_user" "quang" {
  identity_store_id = local.identity_store_id
  user_name         = "quang"
  display_name      = "Quang Chu Hong"

  name {
    given_name  = "Quang"
    family_name = "Chu Hong"
  }

  emails {
    value   = "ban@example.com"   # chi de nhan thu dat password,
    primary = true                # KHONG can duy nhat toan cau
  }
}

resource "aws_identitystore_group_membership" "quang_platform" {
  identity_store_id = local.identity_store_id
  group_id          = aws_identitystore_group.platform.group_id
  member_id         = aws_identitystore_user.quang.user_id
}
```

> **Khác biệt quan trọng với doc 08:** ở đó dùng `data "aws_identitystore_group"` chứ không phải `resource`, vì SCIM từ AD làm chủ user/group nên Terraform chỉ được **đọc**. Không có AD thì ngược lại: Terraform **làm chủ**, dùng `resource`. Đừng trộn hai kiểu — SCIM ghi đè, Terraform thấy drift, apply lại, lặp vô tận.

**2. Ba set `admin`/`developer`/`readonly` không đủ để tách quyền theo miền.** Bộ đầy đủ cho enterprise — 17 set chia theo (network / security / server / database / analytics / app) × (admin / operator), kèm chốt `iam:PassRole`, permissions boundary, và chính sách break-glass — ở [19 – Permission set cho LZ](./19-Permission-Set-cho-Landing-Zone.md), code chạy được tại [`landing-zone/permission-sets/`](../landing-zone/permission-sets/).

---

## 11. Network baseline – TGW hub và centralized egress

Mô hình phổ biến: mỗi account workload có VPC riêng (spoke), tất cả attach vào một **Transit Gateway** ở account `network`; traffic ra Internet đi qua NAT Gateway tập trung.

```text
 app-dev VPC          app-prod VPC
 10.10.0.0/16         10.20.0.0/16
      │                    │
      └──── TGW attach ────┴──────► Transit Gateway (network account)
                                          │
                                    egress VPC 10.0.0.0/16
                                          │
                                    NAT GW → Internet Gateway
```

### 11.1. 5-network/main.tf (phần hub)

```hcl
variable "network_account_id" { type = string }
variable "organization_arn" { type = string }

provider "aws" {
  alias  = "network"
  region = "ap-southeast-1"

  assume_role {
    role_arn = "arn:aws:iam::${var.network_account_id}:role/OrganizationAccountAccessRole"
  }
}

resource "aws_ec2_transit_gateway" "hub" {
  provider    = aws.network
  description = "acme-tgw-hub"

  # Tắt auto-accept/auto-associate để kiểm soát routing thủ công
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "disable"
  default_route_table_propagation = "disable"

  tags = {
    Name = "acme-tgw-hub"
  }
}

# Route table cho spoke: chỉ biết đường ra egress VPC
resource "aws_ec2_transit_gateway_route_table" "spokes" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name = "rtb-spokes"
  }
}

resource "aws_ec2_transit_gateway_route_table" "egress" {
  provider           = aws.network
  transit_gateway_id = aws_ec2_transit_gateway.hub.id

  tags = {
    Name = "rtb-egress"
  }
}

########################
# Share TGW cho cả org qua RAM
########################

resource "aws_ram_resource_share" "tgw" {
  provider                  = aws.network
  name                      = "acme-tgw-share"
  allow_external_principals = false
}

resource "aws_ram_resource_association" "tgw" {
  provider           = aws.network
  resource_arn       = aws_ec2_transit_gateway.hub.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

resource "aws_ram_principal_association" "org" {
  provider           = aws.network
  principal          = var.organization_arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}
```

### 11.2. Quy hoạch CIDR

Đặt trước, đừng để mỗi team tự chọn rồi trùng nhau:

| Vùng | CIDR | Ghi chú |
|---|---|---|
| Egress / shared services | `10.0.0.0/16` | network account |
| NonProd | `10.10.0.0/14` | dev, staging, … |
| Prod | `10.20.0.0/14` | |
| Sandbox | `10.60.0.0/14` | không attach TGW |
| Dự phòng | `10.100.0.0/12` | mở rộng sau |

Dùng **VPC IPAM** nếu muốn AWS tự cấp phát và chống trùng:

```hcl
resource "aws_vpc_ipam" "this" {
  provider = aws.network

  operating_regions {
    region_name = "ap-southeast-1"
  }
}
```

> Với workload thuần serverless như ví dụ 01–05 (Lambda không đặt trong VPC), bạn **chưa cần** TGW. Chỉ dựng phần này khi có RDS/ElastiCache/EC2 hoặc Lambda cần chạy trong VPC.

Mô hình đầy đủ cho enterprise gồm bốn doc, đọc theo thứ tự:

| Doc | Nội dung |
|---|---|
| [13 – Centralized Ingress/Egress](./13-Centralized-Ingress-Egress-Network.md) | Khoá Internet ở mọi account, tách ingress VPC và egress VPC, SCP đi kèm |
| [14 – Ingress Chain](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | Chuỗi CDN → Palo Alto (GWLB) → F5 WAF → App |
| [15 – Security VPC](./15-Security-VPC-Network-Firewall.md) | Mọi traffic (ra, vào, và giữa các account) qua AWS Network Firewall |
| [16 – Kết nối đối tác](./16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) | 3rd-party VPC và Site-to-Site VPN cho mạng bên ngoài |

Phần **DNS tập trung** tách riêng thành hai bản tuỳ theo môi trường:

- Thuần AWS, không on-premise → [12 – DNS và VPC Endpoint tập trung](./12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) (rẻ hơn ~$360/tháng, bỏ được resolver endpoint)
- Có AD on-premise và Microsoft 365 → [07 – Centralized DNS hybrid](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md)

---

## 12. Account baseline – áp cho mọi account

Module này chạy cho **từng account** ngay sau khi tạo. Đây là thứ biến "một account trống" thành "một account đạt chuẩn".

### 12.1. modules/account-baseline/main.tf

```hcl
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.target]
    }
  }
}

variable "account_name" { type = string }
variable "config_bucket_name" { type = string }

########################
# Chặn S3 public ở mức account
########################

resource "aws_s3_account_public_access_block" "this" {
  provider                = aws.target
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

########################
# Mã hoá EBS mặc định
########################

resource "aws_ebs_encryption_by_default" "this" {
  provider = aws.target
  enabled  = true
}

########################
# IMDSv2 bắt buộc cho instance mới
########################

resource "aws_ec2_instance_metadata_defaults" "this" {
  provider                    = aws.target
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}

########################
# IAM password policy
########################

resource "aws_iam_account_password_policy" "this" {
  provider                       = aws.target
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
}

########################
# AWS Config recorder
########################

resource "aws_iam_role" "config" {
  provider = aws.target
  name     = "AcmeAccountBaselineConfigRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  provider   = aws.target
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  provider = aws.target
  name     = "default"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "this" {
  provider       = aws.target
  name           = "default"
  s3_bucket_name = var.config_bucket_name

  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  provider   = aws.target
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

########################
# Budget alert
########################

variable "monthly_budget_usd" {
  type    = string
  default = "100"
}

variable "alert_email" { type = string }

resource "aws_budgets_budget" "monthly" {
  provider     = aws.target
  name         = "${var.account_name}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
```

### 12.2. Gọi module

```hcl
module "baseline_app_dev" {
  source = "../modules/account-baseline"

  providers = {
    aws.target = aws.app_dev
  }

  account_name       = "app-dev"
  config_bucket_name = "acme-config-${var.log_archive_account_id}"
  monthly_budget_usd = "200"
  alert_email        = "platform@acme.com"
}
```

Ngoài ra nên xoá **default VPC** ở mọi region không dùng (Config rule hay soi chỗ này), và bật **VPC Flow Logs** đẩy về log-archive nếu có VPC thật.

---

## 13. Thứ tự deploy

```bash
# 0. Bootstrap state (chạy ở management account, credential admin)
cd 0-bootstrap && terraform init && terraform apply

# 1. Organization: OU + accounts + SCP
#    -> tạo account mất vài phút/account
cd ../1-organization && terraform init && terraform apply
terraform output account_ids

# 2. Logging: bucket + org trail
cd ../2-logging
terraform init
terraform apply \
  -var="log_archive_account_id=222222222222" \
  -var="organization_id=o-xxxxxxxxxx"

# 3. Security: GuardDuty + Security Hub + Config aggregator
cd ../3-security
terraform init
terraform apply -var="security_account_id=333333333333"

# 4. Identity Center (enable instance trong console TRƯỚC)
cd ../4-identity-center && terraform init && terraform apply

# 5. Network (bỏ qua nếu workload thuần serverless)
cd ../5-network && terraform init && terraform apply
```

Bẫy hay gặp:

- **SCP attach root quá sớm** → chính Terraform của bạn bị chặn. Test ở OU Sandbox trước.
- **`aws_organizations_account` bị destroy** → account không bị xoá, chỉ rời khỏi Terraform state. Đặt `prevent_destroy = true` cho chắc.
- **Identity Center chỉ tồn tại ở một region** cho cả org. Chọn region kỹ, đổi sau phải xoá và làm lại toàn bộ assignment.
- **Config recorder chỉ được một cái/account/region.** Nếu account đã có sẵn recorder (do Control Tower hoặc ai đó bật tay), `terraform apply` sẽ lỗi – import nó vào state thay vì tạo mới.
- **GuardDuty delegated admin** phải làm từ management account, và không thể đổi sang account khác khi đang có member đang enable.

---

## 14. Kiểm tra sau khi dựng

```bash
# Cây OU + account
aws organizations list-roots
aws organizations list-organizational-units-for-parent --parent-id r-xxxx
aws organizations list-accounts --query 'Accounts[].[Id,Name,Status]' --output table

# SCP đang attach ở đâu
aws organizations list-policies --filter SERVICE_CONTROL_POLICY
aws organizations list-targets-for-policy --policy-id p-xxxxxxxx

# Org trail có đang chạy không
aws cloudtrail get-trail-status --name acme-org-trail

# Log đã về chưa (chạy với profile log-archive)
aws s3 ls s3://acme-org-cloudtrail-222222222222/AWSLogs/o-xxxxxxxxxx/ --profile log-archive

# GuardDuty member (chạy với profile security)
aws guardduty list-detectors --profile security
aws guardduty list-members --detector-id <id> --profile security

# Thử vi phạm SCP: tạo resource ở region bị cấm → phải bị AccessDenied
aws s3api create-bucket --bucket test-scp-deny-xyz --region eu-west-1 --profile app-dev
# An error occurred (AccessDenied) ... with an explicit deny in a service control policy
```

Dòng cuối chính là bài test quan trọng nhất: nếu nó **không** bị deny thì SCP chưa ăn.

---

## 15. Chi phí ước tính

Con số tham khảo cho org ~5 account, region ap-southeast-1 (kiểm tra lại bằng Pricing Calculator trước khi cam kết):

| Hạng mục | Ước tính / tháng |
|---|---|
| AWS Organizations, SCP, Identity Center | $0 |
| CloudTrail – management events (trail đầu tiên) | $0 |
| CloudTrail – data events | Theo lượng event, dễ vượt $50 nếu bật rộng |
| S3 lưu log (~50 GB, có lifecycle) | ~$1–2 |
| AWS Config (~5 account, vài nghìn config item) | ~$10–30 |
| GuardDuty (5 account, workload nhẹ) | ~$15–40 |
| Security Hub (số check × số account) | ~$10–25 |
| Transit Gateway (attachment $0.05/h + data processing) | ~$36/attachment + traffic |
| NAT Gateway (egress tập trung) | ~$33 + $0.045/GB |

Nhìn bảng này sẽ thấy: LZ cho workload **thuần serverless** thì rất rẻ (bỏ TGW + NAT là tiết kiệm ~$70+/tháng). Chỉ dựng phần network khi thực sự cần.

Cách cắt chi phí nhanh:

- Config: dùng `recording_group` chọn lọc resource type thay vì `all_supported = true`.
- CloudTrail data events: chỉ bật cho bucket/Lambda nhạy cảm, không bật `AWS::S3::Object` toàn bộ.
- Lifecycle S3: chuyển Glacier IR sau 90 ngày như ở mục 8.

---

## 16. Hướng mở rộng

- **Account vending tự động**: team tự request account mới qua ticket, LZ tự apply baseline → [09 – Account Vending tự động](./09-Account-Vending-Tu-Dong.md).
- **CI/CD cho LZ**: `terraform plan` trên PR bằng GitHub Actions + OIDC (không dùng access key), approval cho `apply` ở tầng organization → [10 – CI/CD cho Landing Zone](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md).
- **Tag policy + cost allocation**: bắt buộc tag `CostCenter`, `Owner`, `Environment`; chia bill theo team → [11 – Tag Policy và Cost Allocation](./11-Tag-Policy-va-Cost-Allocation.md).
- **Backup tập trung**: AWS Backup với backup policy ở mức org, vault khoá ở account riêng.
- **Detective controls**: EventBridge rule bắt Security Hub finding severity CRITICAL → SNS → Slack (dùng lại pattern DLQ alert ở ví dụ 01).
- **DNS tập trung + hybrid AD + Microsoft 365**: xem [07 – Centralized DNS](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md).
- **Đồng bộ user/group từ AD on-premise**: xem [08 – Đồng bộ user AD sang Identity Center](./08-Dong-bo-User-AD-sang-IAM-Identity-Center.md).
- **Deploy workload lên trên**: các ví dụ 01–05 giờ deploy vào account `app-dev` / `app-prod`, dùng profile SSO thay vì access key.
