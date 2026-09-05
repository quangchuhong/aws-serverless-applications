# Account Vending tự động – từ ticket đến account đạt chuẩn

Ví dụ 09: Tự động hoá việc "phát" AWS account mới, tiếp nối [06 – Landing Zone](./06-Aws-Landing-Zone.md).

Mục tiêu: team cần account mới → tạo ticket → account xuất hiện sau ~20 phút với **đầy đủ baseline** (SCP, logging, GuardDuty, budget, Identity Center assignment), không ai phải click console.

---

## 1. Vì sao cần vending

Làm tay một account mới nghĩa là khoảng 15 thao tác rời rạc:

```text
tạo account → chờ email verify → đặt OU → gỡ default VPC (× N region)
→ bật S3 public access block → bật EBS encryption → tạo Config recorder
→ enroll GuardDuty → tạo budget → tạo permission set assignment
→ tạo group AD → gán vào enterprise app → chờ SCIM → báo team
```

Vấn đề không phải là mất thời gian, mà là **mỗi lần làm lại thiếu một bước khác nhau**. Sáu tháng sau bạn có 15 account với 15 mức tuân thủ khác nhau, và không ai biết account nào thiếu gì.

Vending giải quyết bằng cách biến quy trình đó thành code chạy y hệt nhau mọi lần.

---

## 2. Chọn cách làm

| Cách | Yêu cầu | Ưu | Nhược |
|---|---|---|---|
| **AFT** (Account Factory for Terraform) | **Bắt buộc có Control Tower** | AWS dựng sẵn toàn bộ pipeline | Kéo theo cả Control Tower; khó tuỳ biến |
| **Service Catalog + Lambda** | Không | Có portal self-service đẹp | Phải tự viết logic vending |
| **Account request as code** (bài này) | Không | Đơn giản, audit qua Git, hợp với LZ tự build | Không có UI, đi qua PR |

Doc 06 chọn hướng **tự build Terraform, không dùng Control Tower** — nên **AFT không dùng được** (AFT bám chặt vào Control Tower Account Factory). Bài này đi hướng thứ ba: mỗi account là một file YAML trong Git.

Nếu tổ chức bạn đã hoặc sẽ dùng Control Tower thì đọc mục 9 để so sánh với AFT.

---

## 3. Kiến trúc

```text
┌──────────────┐   1. Ticket    ┌──────────────┐   2. Tạo PR    ┌───────────────┐
│ Team xin     │───────────────►│ Jira Service │───────────────►│ Git repo      │
│ account mới  │  (form JSM)    │ Management   │  (automation)  │ accounts/*.yml│
└──────────────┘                └──────┬───────┘                └───────┬───────┘
                                       │                                │
                                 3. Approval                      4. Merge PR
                                 (Platform lead)                        │
                                                                        ▼
                                                          ┌─────────────────────────┐
                                                          │ Pipeline (GitHub Actions│
                                                          │ hoặc Jenkins – doc 10)  │
                                                          └───────────┬─────────────┘
                                                                      │
                    ┌─────────────────────────────────────────────────┤
                    ▼                        ▼                        ▼
       ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
       │ 5a. Organizations  │   │ 5b. StackSet       │   │ 5c. Terraform      │
       │ CreateAccount      │──►│ auto-deploy khi    │──►│ baseline module    │
       │ + đặt vào OU       │   │ account vào OU     │   │ (doc 06 mục 12)    │
       └────────────────────┘   └────────────────────┘   └────────────────────┘
                    │                                              │
                    │           ┌──────────────────────────────────┘
                    ▼           ▼
       ┌─────────────────────────────────┐   6. Báo kết quả về ticket
       │ Account đã đạt chuẩn:            │──────────────────────────►
       │ SCP kế thừa từ OU               │
       │ CloudTrail/GuardDuty/Config auto│
       │ Budget + Identity Center gán sẵn│
       └─────────────────────────────────┘
```

Ba lớp áp baseline, mỗi lớp làm việc nó giỏi nhất:

| Lớp | Cơ chế | Áp cái gì | Khi nào chạy |
|---|---|---|---|
| **SCP** | Kế thừa theo OU | Guardrail cấm đoán | Ngay khi account vào OU |
| **StackSet** | Auto-deployment theo OU | IAM role bootstrap, Config recorder | Tự động, vài phút sau |
| **Terraform** | Pipeline assume role | Phần còn lại của baseline | Sau khi pipeline chạy |

Lớp SCP và StackSet chạy **tự động không cần pipeline** — đây là điểm quan trọng: kể cả khi ai đó tạo account bằng tay qua console, nó vẫn dính guardrail ngay khi được đặt vào OU.

---

## 3b. Quy ước email account

Ràng buộc cứng của AWS, quyết định mọi thứ khác trong mục này:

> Mỗi AWS account phải có một email **duy nhất trên toàn cầu**, **vĩnh viễn**. Email đã gắn một account thì không tái sử dụng được — kể cả sau khi đóng account đó.

### Không có domain công ty: dùng plus-addressing

Phần còn lại của tài liệu này giả định domain công ty (`aws+<ten>@acme.com`). Với lab cá nhân thì Gmail hỗ trợ `+`, và AWS chấp nhận `+` trong email account — **một** hộp thư, **vô hạn** địa chỉ:

```
quang.hong.0991+lz-network-01@gmail.com
quang.hong.0991+lz-security-01@gmail.com
quang.hong.0991+lz-app-dev-01@gmail.com
```

Tất cả về đúng một inbox. Đây là email **thật** — AWS gửi được, reset password root được.

> **Thêm hậu tố phiên bản (`-01`) ngay từ đầu.** Đóng account rồi muốn dựng lại với cùng email → `EMAIL_ALREADY_EXISTS`. Lần dựng lại dùng `-02`. Rẻ hơn nhiều so với lúc kẹt mới nghĩ ra.

### Dùng email không có thật thì sao

Với lab thì **chạy được**, nhưng biết trước cái gì hỏng vĩnh viễn:

| | Với email giả |
|---|---|
| Tạo account qua Organizations | ✅ Chạy — AWS **không** bắt verify cho member account |
| Vào account làm việc | ✅ Chạy — qua `OrganizationAccountAccessRole` |
| Identity Center / permission set | ✅ Chạy — không liên quan email root |
| Đóng account | ✅ `aws organizations close-account` từ management, không cần root |
| **Đăng nhập root của account đó** | ❌ **Không bao giờ** — reset password cần email |
| **Đổi email của account về sau** | ❌ Cần root → **kẹt vĩnh viễn với email giả** |
| Nhận cảnh báo bảo mật | ❌ Thư đi vào hư không |

Bốn dòng đầu là thứ bạn dùng 99% thời gian, nên lab vẫn dựng được. Dòng đáng cân nhắc nhất là **đổi email về sau**: account đó không nâng lên dùng thật được.

Vì plus-addressing tốn **đúng bằng** công sức gõ một email giả, gần như không có lý do chọn cái giả.

Nếu vẫn dùng: **tránh domain có thật mà bạn không sở hữu**. Dùng `example.com` / `example.org` / `invalid` — các domain được RFC dành riêng, đảm bảo không thuộc về ai.

> Có cơ chế mới hơn — **centralized root access management** trong Organizations — cho phép management account xoá credential root của account con và thực hiện vài thao tác đặc quyền tập trung. Nếu tài khoản bạn có, nó bù được phần lớn rủi ro "không vào được root". Kiểm chứng ở console IAM → *Root access management* trước khi dựa vào.

### Sau khi tạo account: hai việc làm ngay

Account con tạo qua Organizations **không có password root** và cũng không tự khoá.

1. **Giành lại root từng account** — *Forgot password* với email account đó, đặt password, **bật MFA ngay**. Bỏ qua bước này thì root account con đang ở trạng thái không ai kiểm soát. *(Không làm được nếu dùng email giả — đó chính là cái giá.)*
2. **Việc hằng ngày dùng `OrganizationAccountAccessRole`**, rồi chuyển sang permission set khi Identity Center sẵn sàng ([doc 19](./19-Permission-Set-cho-Landing-Zone.md)).

---

## 4. Account request as code

### 4.1. Schema file request

```yaml
# accounts/app-payments-prod.yaml
account_name:  "acme-app-payments-prod"
email:         "aws+app-payments-prod@acme.com"
ou:            "workloads_prod"          # key trong module organization

owner:
  team:        "payments"
  email:       "payments-eng@acme.com"
  manager:     "tranthib@acme.com"

tags:
  CostCenter:  "CC-4021"
  Environment: "prod"
  Project:     "payments-platform"
  DataClassification: "confidential"

budget:
  monthly_usd: "3000"
  alert_email: "payments-eng@acme.com"

access:
  # sinh ra group AD + assignment (doc 08)
  - permission_set: "DeveloperAccess"
    ad_group:       "AWS-app-payments-prod-Developer"
  - permission_set: "ReadOnlyAccess"
    ad_group:       "AWS-app-payments-prod-ReadOnly"

network:
  enabled:     true
  cidr:        "10.24.0.0/16"
  attach_tgw:  true

jira_ticket: "OPS-1234"
```

Vì sao YAML mà không phải HCL: người tạo request (team lead, PM) không cần biết Terraform. File này đủ đơn giản để review trong PR mà không cần đọc code.

> **Bản đã chạy thật** nằm ở [`landing-zone/account-baseline`](../landing-zone/account-baseline/README.md) — một file `catalog/accounts.yaml` cho mọi request thay vì một file mỗi account, và tên trường ngắn hơn khối ở trên. Khác biệt đáng kể nhất không nằm ở schema: **khối `network` không dùng được ở lần apply đầu tiên của một account mới.** TGW không chia sẻ được cho một account chưa tồn tại, và lời mời RAM phải do chính account đó chấp nhận — nên việc nối một account vào lưới mạng là **năm bước qua ba layer**, không phải một `apply`. Trình tự đầy đủ ở README của layer đó, mục *"Năm bước, ba layer, và không gộp được"*.

### 4.2. Terraform đọc thư mục request

```hcl
# 1-organization/accounts.tf

locals {
  request_files = fileset("${path.module}/accounts", "*.yaml")

  requests = {
    for f in local.request_files :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.module}/accounts/${f}"))
  }

  ou_ids = {
    security          = aws_organizations_organizational_unit.security.id
    infrastructure    = aws_organizations_organizational_unit.infrastructure.id
    workloads_nonprod = aws_organizations_organizational_unit.workloads_nonprod.id
    workloads_prod    = aws_organizations_organizational_unit.workloads_prod.id
    sandbox           = aws_organizations_organizational_unit.sandbox.id
  }
}

########################
# Validate request trước khi tạo account
########################

resource "terraform_data" "validate_requests" {
  for_each = local.requests

  lifecycle {
    precondition {
      condition     = contains(keys(local.ou_ids), each.value.ou)
      error_message = "${each.key}: OU '${each.value.ou}' khong ton tai."
    }

    precondition {
      condition     = can(regex("^aws\\+[a-z0-9-]+@acme\\.com$", each.value.email))
      error_message = "${each.key}: email phai dang aws+<ten>@acme.com."
    }

    precondition {
      condition = alltrue([
        for k in ["CostCenter", "Environment", "Project"] :
        contains(keys(each.value.tags), k)
      ])
      error_message = "${each.key}: thieu tag bat buoc (CostCenter/Environment/Project)."
    }

    precondition {
      condition     = contains(["dev", "staging", "prod", "sandbox"], each.value.tags.Environment)
      error_message = "${each.key}: Environment khong hop le."
    }
  }
}

########################
# Tạo account
########################

resource "aws_organizations_account" "vended" {
  for_each = local.requests

  name              = each.value.account_name
  email             = each.value.email
  parent_id         = local.ou_ids[each.value.ou]
  role_name         = "OrganizationAccountAccessRole"
  close_on_deletion = false

  tags = merge(each.value.tags, {
    Owner       = each.value.owner.email
    Team        = each.value.owner.team
    JiraTicket  = try(each.value.jira_ticket, "n/a")
    ManagedBy   = "terraform-account-vending"
  })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }

  depends_on = [terraform_data.validate_requests]
}

output "vended_accounts" {
  value = {
    for k, v in aws_organizations_account.vended :
    k => {
      id    = v.id
      arn   = v.arn
      email = v.email
      ou    = local.requests[k].ou
    }
  }
}
```

`precondition` chạy **trước** khi tạo resource — request sai format sẽ fail ở `terraform plan` trong PR, chưa đụng gì tới AWS. Đây là lớp bảo vệ rẻ nhất bạn có thể thêm.

### 4.3. Thêm account mới = thêm một file

Toàn bộ quy trình cho team xin account:

```bash
git checkout -b account/app-payments-prod
cp accounts/_template.yaml accounts/app-payments-prod.yaml
# sửa nội dung
git commit -am "Request account: app-payments-prod (OPS-1234)"
git push
# mở PR -> platform team review -> merge -> pipeline chạy
```

PR chính là hồ sơ audit: ai xin, ai duyệt, lúc nào, ticket nào. Không cần hệ thống ghi log riêng.

---

## 5. Baseline tự động bằng CloudFormation StackSets

Đây là mảnh ghép làm cho vending thực sự đáng tin: **StackSet với `auto_deployment` sẽ tự apply vào bất kỳ account nào được đặt vào OU**, kể cả account tạo bằng tay hay account mời từ ngoài vào.

### 5.1. Terraform cho StackSet

```hcl
# 1-organization/stackset-baseline.tf

resource "aws_cloudformation_stack_set" "baseline" {
  name             = "acme-account-bootstrap"
  description      = "IAM role + Config recorder cho moi account trong org"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]

  auto_deployment {
    enabled                          = true
    retain_stacks_on_account_removal = false
  }

  parameters = {
    ManagementAccountId = data.aws_caller_identity.current.account_id
    ConfigBucketName    = "acme-config-${var.log_archive_account_id}"
  }

  template_body = file("${path.module}/templates/account-bootstrap.yaml")

  operation_preferences {
    failure_tolerance_percentage = 10
    max_concurrent_percentage    = 25
    region_concurrency_type      = "PARALLEL"
  }
}

resource "aws_cloudformation_stack_set_instance" "baseline" {
  for_each = toset([
    aws_organizations_organizational_unit.workloads_nonprod.id,
    aws_organizations_organizational_unit.workloads_prod.id,
    aws_organizations_organizational_unit.infrastructure.id,
    aws_organizations_organizational_unit.sandbox.id,
  ])

  stack_set_name = aws_cloudformation_stack_set.baseline.name
  region         = "ap-southeast-1"

  deployment_targets {
    organizational_unit_ids = [each.value]
  }
}
```

### 5.2. templates/account-bootstrap.yaml

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: Bootstrap toi thieu cho moi account trong Acme Landing Zone

Parameters:
  ManagementAccountId:
    Type: String
  ConfigBucketName:
    Type: String

Resources:

  # Role de pipeline Terraform vao account nay.
  # Account tao qua Organizations da co OrganizationAccountAccessRole,
  # nhung account MOI TU NGOAI VAO thi khong -> role nay lap khoang trong do.
  LandingZoneExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: AcmeLandingZoneExecutionRole
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              AWS: !Sub "arn:aws:iam::${ManagementAccountId}:root"
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                sts:ExternalId: acme-landing-zone
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AdministratorAccess
      Tags:
        - Key: ManagedBy
          Value: landing-zone-stackset

  ConfigRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: AcmeAccountBaselineConfigRole
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: config.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWS_ConfigRole

  ConfigRecorder:
    Type: AWS::Config::ConfigurationRecorder
    Properties:
      Name: default
      RoleARN: !GetAtt ConfigRole.Arn
      RecordingGroup:
        AllSupported: true
        IncludeGlobalResourceTypes: true

  ConfigDeliveryChannel:
    Type: AWS::Config::DeliveryChannel
    Properties:
      Name: default
      S3BucketName: !Ref ConfigBucketName

Outputs:
  ExecutionRoleArn:
    Value: !GetAtt LandingZoneExecutionRole.Arn
```

> Một số mục baseline **không có resource CloudFormation tương ứng**: bật mã hoá EBS mặc định, IAM password policy, S3 account-level public access block. Những thứ này nằm ở module Terraform `account-baseline` ([doc 06 mục 12](./06-Aws-Landing-Zone.md)) và được pipeline apply ở bước sau. Đừng cố nhét chúng vào CloudFormation bằng custom resource trừ khi thật sự cần chúng có mặt trước cả pipeline.

### 5.3. Pipeline apply phần Terraform baseline

Sau khi account tồn tại, pipeline chạy tiếp:

```hcl
# 7-account-baseline/main.tf

variable "accounts" {
  description = "Output vended_accounts tu 1-organization"
  type = map(object({
    id    = string
    email = string
    ou    = string
  }))
}

# Provider động cho từng account là hạn chế lớn của Terraform:
# for_each KHÔNG dùng được với provider. Ba cách xử lý:
#   1. Mỗi account một workspace/state riêng (khuyến nghị)
#   2. Sinh code bằng template (terragrunt, hoặc script)
#   3. Khai báo tay provider alias cho từng account
#
# Bài này dùng cách 1 – pipeline lặp qua danh sách account:

variable "target_account_id" { type = string }

provider "aws" {
  region = "ap-southeast-1"

  assume_role {
    role_arn     = "arn:aws:iam::${var.target_account_id}:role/AcmeLandingZoneExecutionRole"
    external_id  = "acme-landing-zone"
  }
}

module "baseline" {
  source = "../modules/account-baseline"

  providers = { aws.target = aws }

  account_name       = var.account_name
  config_bucket_name = var.config_bucket_name
  monthly_budget_usd = var.monthly_budget_usd
  alert_email        = var.alert_email
}
```

Pipeline lặp:

```bash
# Đọc danh sách account từ output của 1-organization
ACCOUNTS=$(terraform -chdir=1-organization output -json vended_accounts)

echo "$ACCOUNTS" | jq -r 'to_entries[] | @base64' | while read -r row; do
  entry=$(echo "$row" | base64 -d)
  key=$(echo "$entry" | jq -r '.key')
  id=$(echo "$entry" | jq -r '.value.id')

  echo "=== Baseline cho $key ($id) ==="
  terraform -chdir=7-account-baseline init -reconfigure \
    -backend-config="key=account-baseline/${key}.tfstate"

  terraform -chdir=7-account-baseline apply -auto-approve \
    -var="target_account_id=${id}" \
    -var="account_name=${key}"
done
```

Mỗi account một state file riêng — hỏng một account không kéo theo account khác.

---

## 6. Nối với luồng ticket JSM

Repo đã có sẵn thiết kế JSM → CI ở [`jirasm-automation-draft.md`](./jirasm-automation-draft.md). Vending account dùng lại đúng khung đó, chỉ khác ở chỗ CI không deploy mà **tạo PR**:

```text
1. User tạo ticket JSM loại "AWS Account Request"
   Custom fields: Team, Environment, CostCenter, Budget, CIDR, Manager

2. JSM workflow: Open → Manager Approval → Platform Approval → Approved

3. Jira Automation Rule khi status = Approved:
   Send Web Request → CI với body JSON

4. CI job "account-request":
   - Sinh file accounts/<name>.yaml từ payload
   - Tạo branch account/<name>
   - Commit + push, mở PR, gắn nhãn "account-vending"
   - Comment link PR ngược về ticket

5. Platform team review PR (bước kiểm soát cuối cùng)

6. Merge → pipeline LZ chạy (doc 10)

7. Pipeline gọi lại Jira REST API:
   POST /issue/OPS-1234/comment  → account ID, SSO URL, hướng dẫn login
   POST /issue/OPS-1234/transitions → Succeeded
```

Script sinh file YAML từ payload webhook:

```bash
#!/usr/bin/env bash
# ci/create-account-request.sh
set -euo pipefail

PAYLOAD="${1:?Thieu file payload JSON tu Jira}"

NAME=$(jq -r '.accountName'  "$PAYLOAD")
TEAM=$(jq -r '.team'         "$PAYLOAD")
ENVIRONMENT=$(jq -r '.env'   "$PAYLOAD")
COST_CENTER=$(jq -r '.costCenter' "$PAYLOAD")
BUDGET=$(jq -r '.budgetUsd'  "$PAYLOAD")
OWNER_EMAIL=$(jq -r '.ownerEmail' "$PAYLOAD")
ISSUE_KEY=$(jq -r '.issueKey' "$PAYLOAD")

case "$ENVIRONMENT" in
  prod)            OU="workloads_prod"    ;;
  dev|staging)     OU="workloads_nonprod" ;;
  sandbox)         OU="sandbox"           ;;
  *) echo "Environment khong hop le: $ENVIRONMENT" >&2; exit 1 ;;
esac

cat > "accounts/${NAME}.yaml" <<EOF
account_name:  "acme-${NAME}"
email:         "aws+${NAME}@acme.com"
ou:            "${OU}"

owner:
  team:        "${TEAM}"
  email:       "${OWNER_EMAIL}"

tags:
  CostCenter:  "${COST_CENTER}"
  Environment: "${ENVIRONMENT}"
  Project:     "${TEAM}"

budget:
  monthly_usd: "${BUDGET}"
  alert_email: "${OWNER_EMAIL}"

jira_ticket: "${ISSUE_KEY}"
EOF

git checkout -b "account/${NAME}"
git add "accounts/${NAME}.yaml"
git commit -m "Request account: ${NAME} (${ISSUE_KEY})"
git push -u origin "account/${NAME}"

gh pr create \
  --title "Account request: ${NAME} (${ISSUE_KEY})" \
  --body  "Tu ticket ${ISSUE_KEY}. Team: ${TEAM}. Env: ${ENVIRONMENT}. Budget: \$${BUDGET}/thang." \
  --label "account-vending"
```

Giữ bước review PR thủ công. Vending tự động hoá phần *thao tác*, không tự động hoá phần *quyết định* — tạo account là việc tốn tiền và khó đảo ngược.

---

## 7. Service Catalog – portal self-service

Nếu muốn UI thay vì PR, bọc vending thành một **Service Catalog product**:

```hcl
resource "aws_servicecatalog_portfolio" "lz" {
  name          = "Acme Landing Zone"
  description   = "Self-service cho team noi bo"
  provider_name = "Platform Team"
}

resource "aws_servicecatalog_product" "account_request" {
  name  = "AWS Account Request"
  owner = "Platform Team"
  type  = "CLOUD_FORMATION_TEMPLATE"

  provisioning_artifact_parameters {
    name         = "v1.0"
    template_url = "https://s3.../account-request-product.yaml"
    type         = "CLOUD_FORMATION_TEMPLATE"
  }
}

resource "aws_servicecatalog_product_portfolio_association" "this" {
  portfolio_id = aws_servicecatalog_portfolio.lz.id
  product_id   = aws_servicecatalog_product.account_request.id
}

# Cho phép user Identity Center dùng portfolio (doc 08)
resource "aws_servicecatalog_principal_portfolio_association" "developers" {
  portfolio_id  = aws_servicecatalog_portfolio.lz.id
  principal_arn = "arn:aws:iam::${var.management_account_id}:role/AWSReservedSSO_DeveloperAccess_*"
  principal_type = "IAM_PATTERN"
}
```

Template phía sau chỉ cần một Lambda-backed custom resource: nhận tham số, ghi file YAML, mở PR — tức là dùng lại đúng script mục 6. Portal chỉ là mặt tiền, không phải cơ chế thứ hai.

---

## 8. Vòng đời account

Vending mới là nửa đầu. Nửa sau hay bị bỏ quên:

| Sự kiện | Thao tác | Lưu ý |
|---|---|---|
| **Đổi OU** (dev → prod) | Sửa `ou:` trong YAML | SCP đổi theo ngay; StackSet re-deploy |
| **Đổi owner** | Sửa `owner:` | Nhớ cập nhật budget alert email |
| **Tạm ngưng** | Gỡ Identity Center assignment | Account vẫn tồn tại, vẫn tính tiền |
| **Đóng account** | Xoá file YAML + đóng qua console/API | Không tự động hoá bước này |

Vì sao **không** tự động đóng account: AWS giới hạn số account có thể đóng trong một chu kỳ 30 ngày, account đóng nhầm chỉ khôi phục được trong 90 ngày, và dữ liệu trong đó thường không có bản sao ở đâu khác. Để `close_on_deletion = false` và `prevent_destroy = true`, đóng bằng tay có chủ đích.

Quy trình đóng an toàn:

```bash
# 1. Kiểm tra còn resource gì đang chạy
aws resourcegroupstaggingapi get-resources --profile <account> | jq '.ResourceTagMappingList | length'

# 2. Export dữ liệu cần giữ (S3, RDS snapshot) sang account khác

# 3. Gỡ khỏi Terraform state TRƯỚC (không destroy)
terraform state rm 'aws_organizations_account.vended["app-payments-dev"]'

# 4. Xoá file YAML, commit

# 5. Đóng account qua API
aws organizations close-account --account-id 555555555555
```

---

## 9. Nếu bạn dùng Control Tower: AFT

> **Chọn hướng nào trước đã.** Repo này có code cho **cả hai**: [`landing-zone/organization/`](../landing-zone/organization/) (DIY, bản dùng thật) và [`landing-zone/control-tower/`](../landing-zone/control-tower/) (mặc định tắt, plan ra 0 resource). So sánh chi phí và khi nào chọn cái nào: [21 – Control Tower vs DIY](./21-Control-Tower-vs-DIY.md).


AFT là account vending do AWS dựng sẵn, chạy trên bốn repo:

| Repo | Nội dung |
|---|---|
| `aft-account-request` | Terraform khai báo account cần tạo (tương đương `accounts/*.yaml`) |
| `aft-global-customizations` | Áp cho **mọi** account |
| `aft-account-customizations` | Áp theo từng loại account |
| `aft-account-provisioning-customizations` | Step Functions chèn vào giữa quá trình vending |

So với cách tự build ở bài này:

| | AFT | Account request as code |
|---|---|---|
| Control Tower | Bắt buộc | Không cần |
| Hạ tầng phải nuôi | CodePipeline, CodeBuild, DynamoDB, Step Functions, Lambda (~$30–80/tháng) | Chỉ pipeline có sẵn |
| Thời gian dựng | 1–2 ngày (nếu đã có Control Tower) | 2–3 ngày |
| Debug khi lỗi | Lần qua nhiều lớp Step Functions | Đọc log Terraform |
| Phù hợp | Org lớn, đã chuẩn Control Tower | Org tự build LZ như doc 06 |

Nguyên tắc chọn: **đã có Control Tower thì dùng AFT**, đừng tự viết lại. **Chưa có** thì đừng kéo Control Tower vào chỉ để lấy AFT.

---

## 10. Quota và giới hạn cần biết

| Giới hạn | Giá trị mặc định | Xử lý |
|---|---|---|
| Số account trong org | 10 (soft) | Mở ticket Support tăng trước khi cần |
| Tốc độ `CreateAccount` | Xử lý gần như tuần tự, mỗi account vài phút | `terraform apply -parallelism=1` khi tạo nhiều |
| Email account | Không tái sử dụng được, kể cả sau khi đóng | Dùng plus-addressing có hậu tố ngày nếu cần tạo lại |
| Đóng account | Giới hạn theo tỷ lệ trong chu kỳ 30 ngày | Đóng rải ra, đừng dồn một đợt |
| StackSet instance | Có giới hạn số stack instance đồng thời | Dùng `operation_preferences` giảm concurrency |
| SCP đính kèm | 5 policy/target | Gộp statement thay vì tách nhiều SCP |

Tạo 20 account một lúc bằng `terraform apply` gần như chắc chắn dính throttling. Tách thành nhiều đợt, hoặc đặt `parallelism=1` và chấp nhận chờ.

---

## 11. Kiểm tra

```bash
# Account mới đã đúng OU chưa
aws organizations list-parents --child-id 555555555555

# StackSet đã deploy vào account chưa
aws cloudformation list-stack-instances \
  --stack-set-name acme-account-bootstrap \
  --call-as SELF \
  --query 'Summaries[?Account==`555555555555`].[Account,Region,Status,StatusReason]' \
  --output table

# Role bootstrap đã tồn tại (assume thử)
aws sts assume-role \
  --role-arn "arn:aws:iam::555555555555:role/AcmeLandingZoneExecutionRole" \
  --role-session-name verify \
  --external-id acme-landing-zone

# GuardDuty đã tự enroll (chạy ở security account)
aws guardduty list-members --detector-id <id> --profile security \
  | jq '.Members[] | select(.AccountId=="555555555555")'

# Config recorder đang chạy
aws configservice describe-configuration-recorder-status --profile new-account

# SCP có ăn không – phải bị deny
aws s3api create-bucket --bucket test-scp-xyz --region eu-west-1 --profile new-account

# Budget đã tạo
aws budgets describe-budgets --account-id 555555555555 --profile new-account
```

Gộp các lệnh này thành một script `verify-account.sh` và cho pipeline chạy tự động sau mỗi lần vending — kết quả comment ngược về ticket JSM.

---

## 12. Bẫy hay gặp

| Vấn đề | Nguyên nhân | Cách tránh |
|---|---|---|
| `EMAIL_ALREADY_EXISTS` | Email đã dùng cho account khác (kể cả đã đóng) | Kiểm tra trước, đặt quy ước email chặt |
| Tạo nhiều account cùng lúc bị lỗi | Throttling `CreateAccount` | `-parallelism=1`, chia đợt |
| StackSet không deploy vào account mới | `auto_deployment` chưa bật, hoặc OU không nằm trong `deployment_targets` | Kiểm tra `list-stack-instances` |
| Account mời từ ngoài vào thiếu role | Không có `OrganizationAccountAccessRole` | Chính là lý do StackSet tạo `AcmeLandingZoneExecutionRole` |
| `terraform destroy` xoá nhầm account | Không có `prevent_destroy` | Bật `prevent_destroy` + `close_on_deletion = false` |
| Provider không dùng được `for_each` | Hạn chế của Terraform | Một state/account, lặp ở tầng pipeline |
| Baseline drift sau vài tháng | Không ai chạy lại Terraform | Pipeline chạy `plan` định kỳ, cảnh báo drift (doc 10) |
| Account tạo tay lọt lưới | Người có quyền vẫn click console được | SCP + StackSet theo OU vẫn bắt được; thêm EventBridge cảnh báo `CreateAccountResult` |

Bẫy cuối đáng nói thêm: dựng EventBridge rule bắt sự kiện tạo account ngoài pipeline, gửi cảnh báo — dùng lại pattern alert ở [ví dụ 01](./01-Example-Aws-Serverless-Order-API.md).

```hcl
resource "aws_cloudwatch_event_rule" "account_created_outside_pipeline" {
  name        = "detect-manual-account-creation"
  description = "Canh bao khi co account tao khong qua vending"

  event_pattern = jsonencode({
    source      = ["aws.organizations"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["organizations.amazonaws.com"]
      eventName   = ["CreateAccount", "InviteAccountToOrganization"]
      userIdentity = {
        arn = [{ "anything-but" = { prefix = "arn:aws:sts::*:assumed-role/AcmeLandingZonePipeline" } }]
      }
    }
  })
}
```

---

## 13. Hướng mở rộng

- **Sinh luôn group AD**: từ khối `access:` trong YAML, gọi Graph API tạo group và gán vào enterprise app ([doc 08](./08-Dong-bo-User-AD-sang-IAM-Identity-Center.md)) — khép kín vòng vending–identity.
- **Cấp phát CIDR tự động**: dùng VPC IPAM thay vì nhập tay `network.cidr`, hết cảnh trùng dải.
- **Account ephemeral**: sandbox có TTL, Lambda quét tag `ExpiresAt` và tự đóng account quá hạn.
- **Nesting request**: một ticket sinh cả bộ dev/staging/prod cho một dự án.
- **Chi phí ngay từ đầu**: gắn Cost Category cho account mới ngay lúc vending, xem [11 – Tag Policy và Cost Allocation](./11-Tag-Policy-va-Cost-Allocation.md).
