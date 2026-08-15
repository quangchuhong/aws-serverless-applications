# Tag Policy và Cost Allocation – chia bill theo team

Ví dụ 11: Bắt buộc tag chuẩn trên toàn org và biến tag đó thành báo cáo chi phí theo team, tiếp nối [06 – Landing Zone](./06-Aws-Landing-Zone.md).

Câu hỏi cần trả lời được sau bài này: **"Tháng trước team Payments tiêu bao nhiêu, cho service nào?"** — trả lời trong 30 giây, không cần hỏi ai.

---

## 1. Vì sao tag khó, và vì sao phải làm sớm

Tag là loại việc mà **chi phí sửa sai tăng theo thời gian**. Sáu tháng đầu bỏ qua, đến khi CFO hỏi thì bạn có 3.000 resource không tag, và không có cách nào biết cái nào của ai ngoài việc đi hỏi từng team.

Quan trọng hơn: **cost allocation tag không hồi tố theo mặc định**. Bật tag hôm nay thì dữ liệu chi phí phân bổ bắt đầu từ hôm nay. Dữ liệu tháng trước vẫn nằm đó nhưng không chia theo tag được.

Bốn lớp thực thi, xếp theo thứ tự nên triển khai:

| Lớp | Cơ chế | Tác dụng | Điểm yếu |
|---|---|---|---|
| **1. Terraform `default_tags`** | Provider tự gắn tag | Phủ ~90% resource, không tốn công | Chỉ áp cho resource tạo bằng Terraform |
| **2. Tag Policy** | AWS Organizations | Chuẩn hoá **giá trị** tag (viết hoa, danh sách hợp lệ) | Không chặn được resource tạo *thiếu* tag |
| **3. SCP** | AWS Organizations | **Chặn** tạo resource nếu thiếu tag | Chỉ áp được cho một số action |
| **4. AWS Config** | Detective | Phát hiện resource đã lỡ tạo mà thiếu tag | Sau khi việc đã rồi |

Nhiều người bắt đầu từ lớp 2 vì tên nghe giống nhất với "bắt buộc tag" — rồi ngạc nhiên vì tag policy **không chặn** ai tạo EC2 không tag. Bắt đầu từ lớp 1: rẻ nhất, hiệu quả nhất.

---

## 2. Chuẩn tag

Giữ danh sách bắt buộc **ngắn**. Năm tag là đủ; mười lăm tag thì không ai điền đúng.

| Tag | Bắt buộc | Giá trị hợp lệ | Dùng để |
|---|---|---|---|
| `CostCenter` | ✅ | `CC-####` | Chia bill về phòng ban |
| `Owner` | ✅ | Email | Biết hỏi ai khi có sự cố |
| `Environment` | ✅ | `dev` / `staging` / `prod` / `sandbox` | Lọc chi phí, áp policy |
| `Project` | ✅ | kebab-case | Gom chi phí theo dự án |
| `DataClassification` | prod | `public` / `internal` / `confidential` / `restricted` | Audit, tuân thủ |
| `ManagedBy` | tự động | `terraform` / `console` / `cloudformation` | Phát hiện resource tạo tay |
| `ExpiresAt` | sandbox | `YYYY-MM-DD` | Tự dọn resource hết hạn |

Ba quyết định nên chốt ngay từ đầu vì sau này đổi rất đau:

1. **Phân biệt hoa thường.** `CostCenter` ≠ `costcenter` ≠ `Costcenter` — AWS coi là ba tag khác nhau. Chọn PascalCase và ép bằng tag policy.
2. **Tag key không đổi được.** Đổi tên tag = tạo tag mới + xoá tag cũ trên mọi resource, và lịch sử chi phí gắn với tag cũ thì mất.
3. **Giá trị nên là mã, không phải tên.** `CC-4021` bền hơn `Payments Team` — team đổi tên thì mã vẫn đúng.

---

## 3. Lớp 1: Terraform `default_tags`

Lớp rẻ nhất và hiệu quả nhất. Khai báo một lần ở provider, mọi resource hỗ trợ tag đều được gắn.

```hcl
# modules/provider-config/main.tf
variable "cost_center" { type = string }
variable "owner_email" { type = string }
variable "environment" { type = string }
variable "project"     { type = string }

provider "aws" {
  region = "ap-southeast-1"

  default_tags {
    tags = {
      CostCenter  = var.cost_center
      Owner       = var.owner_email
      Environment = var.environment
      Project     = var.project
      ManagedBy   = "terraform"
      Repository  = "acme/aws-landing-zone"
    }
  }
}
```

Resource nào cần tag riêng thì gộp thêm, `default_tags` vẫn giữ:

```hcl
resource "aws_dynamodb_table" "orders" {
  name = "OrdersTable"
  # ...

  tags = {
    DataClassification = "confidential"
    BackupPolicy       = "daily-35d"
  }
}
```

> Vài resource (điển hình là `aws_autoscaling_group`, và một số resource có cơ chế tag riêng) hay sinh diff lặp lại khi dùng `default_tags`. Gặp trường hợp đó thì khai báo tag tường minh cho resource đó và thêm `ignore_changes` cho `tags_all`.

Áp cùng bộ tag cho account vending ở [doc 09](./09-Account-Vending-Tu-Dong.md) — tag của account chính là nguồn cho `default_tags` của mọi workload trong account đó.

---

## 4. Lớp 2: Tag Policy

Tag policy **chuẩn hoá** tag: ép đúng cách viết hoa và giới hạn giá trị hợp lệ. Nó không bắt ai phải gắn tag.

### 4.1. policies/tag-policy.json

```json
{
  "tags": {
    "CostCenter": {
      "tag_key": {
        "@@assign": "CostCenter"
      },
      "tag_value": {
        "@@assign": [
          "CC-1001",
          "CC-2002",
          "CC-3010",
          "CC-4021"
        ]
      },
      "enforced_for": {
        "@@assign": [
          "ec2:instance",
          "ec2:volume",
          "rds:db",
          "s3:bucket",
          "lambda:function",
          "dynamodb:table"
        ]
      }
    },

    "Environment": {
      "tag_key": {
        "@@assign": "Environment"
      },
      "tag_value": {
        "@@assign": ["dev", "staging", "prod", "sandbox"]
      },
      "enforced_for": {
        "@@assign": [
          "ec2:instance",
          "rds:db",
          "s3:bucket",
          "lambda:function"
        ]
      }
    },

    "Owner": {
      "tag_key": {
        "@@assign": "Owner"
      }
    },

    "Project": {
      "tag_key": {
        "@@assign": "Project"
      }
    }
  }
}
```

Ý nghĩa từng phần:

- `tag_key.@@assign` — ép **đúng cách viết**. Ai gắn `costcenter` sẽ bị coi là non-compliant.
- `tag_value.@@assign` — danh sách giá trị hợp lệ. Bỏ trống nghĩa là giá trị nào cũng được.
- `enforced_for` — với các resource type liệt kê ở đây, thao tác gắn tag **sai giá trị sẽ bị từ chối**. Không có `enforced_for` thì chỉ báo cáo, không chặn.

Điểm cần hiểu rõ: kể cả với `enforced_for`, tag policy **chỉ chặn thao tác tagging sai**, chứ không chặn việc tạo resource hoàn toàn không có tag. Muốn chặn tạo thì cần SCP ở mục 5.

### 4.2. Terraform

```hcl
resource "aws_organizations_policy" "tag_standard" {
  name    = "acme-tag-standard"
  type    = "TAG_POLICY"
  content = file("${path.module}/policies/tag-policy.json")
}

# Roll out theo bậc: Sandbox trước, rồi NonProd, cuối cùng Prod
resource "aws_organizations_policy_attachment" "tag_sandbox" {
  policy_id = aws_organizations_policy.tag_standard.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}

resource "aws_organizations_policy_attachment" "tag_workloads" {
  policy_id = aws_organizations_policy.tag_standard.id
  target_id = aws_organizations_organizational_unit.workloads.id
}
```

Nhớ bật `TAG_POLICY` trong `enabled_policy_types` của `aws_organizations_organization` — [doc 06 mục 6.1](./06-Aws-Landing-Zone.md) đã bật sẵn.

---

## 5. Lớp 3: SCP bắt buộc tag lúc tạo

Đây mới là lớp thực sự chặn.

### 5.1. policies/require-tags.json

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyRunInstancesWithoutTags",
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*"
      ],
      "Condition": {
        "Null": {
          "aws:RequestTag/CostCenter": "true"
        }
      }
    },
    {
      "Sid": "DenyCreateResourcesWithoutCostCenter",
      "Effect": "Deny",
      "Action": [
        "rds:CreateDBInstance",
        "rds:CreateDBCluster",
        "elasticache:CreateCacheCluster",
        "es:CreateDomain",
        "redshift:CreateCluster"
      ],
      "Resource": "*",
      "Condition": {
        "Null": {
          "aws:RequestTag/CostCenter": "true"
        }
      }
    },
    {
      "Sid": "DenyInvalidEnvironmentTag",
      "Effect": "Deny",
      "Action": [
        "ec2:RunInstances",
        "rds:CreateDBInstance"
      ],
      "Resource": "*",
      "Condition": {
        "StringNotEquals": {
          "aws:RequestTag/Environment": [
            "dev",
            "staging",
            "prod",
            "sandbox"
          ]
        }
      }
    },
    {
      "Sid": "DenyRemovingMandatoryTags",
      "Effect": "Deny",
      "Action": [
        "ec2:DeleteTags",
        "rds:RemoveTagsFromResource",
        "lambda:UntagResource",
        "s3:DeleteBucketTagging",
        "dynamodb:UntagResource"
      ],
      "Resource": "*",
      "Condition": {
        "ForAnyValue:StringEquals": {
          "aws:TagKeys": [
            "CostCenter",
            "Owner",
            "Environment"
          ]
        }
      }
    }
  ]
}
```

`DenyRemovingMandatoryTags` là statement hay bị quên: chặn tạo mà không chặn xoá thì ai cũng có thể tạo đúng rồi gỡ tag đi ngay sau đó.

### 5.2. Vì sao không liệt kê được mọi service

Điều kiện `aws:RequestTag` chỉ hoạt động với những action **hỗ trợ tag-on-create**. Nhiều action không hỗ trợ, và với những service đó SCP không giúp được gì — phải dựa vào lớp 1 (Terraform) và lớp 4 (Config).

Cách thực tế: SCP tập trung vào các resource **đắt tiền** (EC2, RDS, Redshift, OpenSearch, ElastiCache). Đó là 80% hoá đơn. Lambda hay S3 thì để `default_tags` lo — chi phí một Lambda không tag hiếm khi làm lệch báo cáo.

Roll out y như SCP khác: Sandbox → NonProd → Prod, mỗi bậc sống vài tuần.

---

## 6. Lớp 4: Phát hiện bằng AWS Config

```hcl
resource "aws_config_organization_managed_rule" "required_tags" {
  provider = aws.security   # delegated admin, doc 06 mục 9

  name            = "required-tags"
  rule_identifier = "REQUIRED_TAGS"

  input_parameters = jsonencode({
    tag1Key = "CostCenter"
    tag2Key = "Owner"
    tag3Key = "Environment"
  })

  resource_types_scope = [
    "AWS::EC2::Instance",
    "AWS::EC2::Volume",
    "AWS::RDS::DBInstance",
    "AWS::S3::Bucket",
    "AWS::Lambda::Function",
    "AWS::DynamoDB::Table",
  ]

  excluded_accounts = [var.management_account_id]
}
```

Báo cáo resource không tuân thủ:

```bash
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name required-tags \
  --compliance-types NON_COMPLIANT \
  --query 'EvaluationResults[].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId' \
  --output table
```

Gắn thêm auto-remediation cho trường hợp nhẹ: Lambda đọc CloudTrail xem ai tạo resource, rồi gắn `Owner` = người đó và `CostCenter` = mã của account. Không hoàn hảo nhưng tốt hơn để trống — dùng lại pattern alert ở [ví dụ 01](./01-Example-Aws-Serverless-Order-API.md) để đồng thời báo về Slack.

---

## 7. Bật cost allocation tag

Tag đã có, giờ nói cho Billing biết tag nào cần theo dõi. **Chỉ làm được ở management account.**

```hcl
resource "aws_ce_cost_allocation_tag" "tracked" {
  for_each = toset([
    "CostCenter",
    "Owner",
    "Environment",
    "Project",
  ])

  tag_key = each.value
  status  = "Active"
}
```

Ba điều cần biết trước khi chạy:

1. **Chậm tới ~24 giờ** để tag xuất hiện trong Cost Explorer sau khi bật.
2. **Mặc định không hồi tố** — dữ liệu phân bổ bắt đầu từ lúc bật. AWS có bổ sung khả năng backfill cho cost allocation tag; kiểm tra trong Billing console xem tài khoản của bạn dùng được không.
3. Tag chỉ xuất hiện trong danh sách **sau khi đã có ít nhất một resource mang tag đó**. Chưa gắn tag ở đâu thì chưa bật được.

Vì lý do 1 và 2, đây là việc nên làm **ngày đầu tiên** của Landing Zone, kể cả khi chưa dùng tới báo cáo.

---

## 8. Cost Categories – gom chi phí theo cấu trúc kinh doanh

Tag hoạt động ở mức resource. **Cost Category** hoạt động ở mức cao hơn: gom account + tag thành đơn vị mà lãnh đạo hiểu được.

```hcl
resource "aws_ce_cost_category" "business_unit" {
  name         = "BusinessUnit"
  rule_version = "CostCategoryExpression.v1"

  rule {
    value = "Payments"
    type  = "REGULAR"

    rule {
      or {
        tags {
          key           = "CostCenter"
          values        = ["CC-4021"]
          match_options = ["EQUALS"]
        }
      }
      or {
        dimension {
          key           = "LINKED_ACCOUNT"
          values        = [var.account_ids["app_payments_prod"]]
          match_options = ["EQUALS"]
        }
      }
    }
  }

  rule {
    value = "Platform"
    type  = "REGULAR"

    rule {
      dimension {
        key    = "LINKED_ACCOUNT"
        values = [
          var.account_ids["network"],
          var.account_ids["security"],
          var.account_ids["log_archive"],
        ]
        match_options = ["EQUALS"]
      }
    }
  }

  rule {
    value = "Sandbox"
    type  = "REGULAR"

    rule {
      tags {
        key           = "Environment"
        values        = ["sandbox"]
        match_options = ["EQUALS"]
      }
    }
  }

  default_value = "Unallocated"

  ########################
  # Chia chi phí hạ tầng dùng chung về các BU
  ########################
  split_charge_rule {
    source  = "Platform"
    targets = ["Payments", "Ecommerce", "DataPlatform"]
    method  = "PROPORTIONAL"
  }
}
```

`split_charge_rule` giải quyết bài toán khó nhất của chargeback: **chi phí hạ tầng dùng chung**. Transit Gateway, NAT Gateway, Route 53 Resolver endpoint, S3 log archive — không thuộc team nào nhưng ai cũng dùng.

Ba cách chia:

| Method | Cách chia | Hợp với |
|---|---|---|
| `PROPORTIONAL` | Theo tỷ lệ chi tiêu của từng BU | Mặc định hợp lý nhất |
| `EVEN` | Chia đều | Khi các team quy mô tương đương |
| `FIXED` | Theo tỷ lệ cố định bạn khai | Khi đã có thoả thuận nội bộ |

Giá trị `Unallocated` ở `default_value` chính là **chỉ số sức khoẻ tag**. Theo dõi nó hàng tháng: đang giảm nghĩa là kỷ luật tag đang tốt lên.

---

## 9. Budget theo team

```hcl
# Budget cho từng cost center
resource "aws_budgets_budget" "by_cost_center" {
  for_each = {
    "CC-4021" = { limit = "5000", email = "payments-eng@acme.com" }
    "CC-3010" = { limit = "8000", email = "ecommerce-eng@acme.com" }
    "CC-2002" = { limit = "2000", email = "data-eng@acme.com" }
  }

  name         = "budget-${each.key}"
  budget_type  = "COST"
  limit_amount = each.value.limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:CostCenter$${each.key}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [each.value.email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [each.value.email, "finops@acme.com"]
  }
}

# Cảnh báo bất thường – bắt được cả những gì budget không bắt được
resource "aws_ce_anomaly_monitor" "by_cost_center" {
  name              = "monitor-by-cost-center"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "finops" {
  name      = "anomaly-alerts"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.by_cost_center.arn]

  subscriber {
    type    = "EMAIL"
    address = "finops@acme.com"
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["100"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}
```

Chú ý cú pháp `"user:CostCenter$${each.key}"` — Cost filter dùng định dạng `user:<TagKey>$<TagValue>`, và `$$` để Terraform xuất ra đúng một dấu `$`.

Budget bắt được "team tiêu quá hạn mức". Anomaly detection bắt được "hôm nay tự nhiên tốn gấp ba lần bình thường" — hai thứ khác nhau, nên có cả hai.

---

## 10. CUR + Athena – báo cáo chargeback

Cost Explorer đủ cho việc xem hằng ngày. Muốn báo cáo tự động gửi từng team thì cần **Cost and Usage Report** đổ vào S3 rồi query bằng Athena.

```hcl
# CUR BẮT BUỘC tạo ở us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_cur_report_definition" "main" {
  provider = aws.us_east_1

  report_name = "acme-cur-hourly"
  time_unit   = "HOURLY"
  format      = "Parquet"
  compression = "Parquet"

  # RESOURCES = có cột resource ID, bắt buộc nếu muốn truy về từng resource
  additional_schema_elements = ["RESOURCES"]

  s3_bucket = aws_s3_bucket.cur.id
  s3_region = "ap-southeast-1"
  s3_prefix = "cur"

  additional_artifacts   = ["ATHENA"]
  report_versioning      = "OVERWRITE_REPORT"
  refresh_closed_reports = true
}
```

> AWS đang chuyển sang **Data Exports (CUR 2.0)** với schema phẳng hơn và hỗ trợ FOCUS. Nếu dựng mới, cân nhắc `aws_bcmdataexports_export` thay cho resource ở trên — kiểm tra tài liệu provider vì schema còn thay đổi.

### 10.1. Query chargeback

```sql
-- Chi phí tháng trước theo CostCenter và service
SELECT
    resource_tags_user_cost_center            AS cost_center,
    line_item_product_code                    AS service,
    ROUND(SUM(line_item_unblended_cost), 2)   AS cost_usd
FROM acme_cur_hourly
WHERE year  = '2026'
  AND month = '07'
  AND line_item_line_item_type IN ('Usage', 'DiscountedUsage', 'SavingsPlanCoveredUsage')
GROUP BY 1, 2
HAVING SUM(line_item_unblended_cost) > 1
ORDER BY cost_usd DESC;
```

```sql
-- Top 20 resource KHÔNG có tag CostCenter – danh sách việc cần làm
SELECT
    line_item_resource_id                     AS resource_id,
    line_item_product_code                    AS service,
    line_item_usage_account_id                AS account_id,
    ROUND(SUM(line_item_unblended_cost), 2)   AS cost_usd
FROM acme_cur_hourly
WHERE year  = '2026'
  AND month = '07'
  AND (resource_tags_user_cost_center IS NULL OR resource_tags_user_cost_center = '')
  AND line_item_resource_id <> ''
GROUP BY 1, 2, 3
ORDER BY cost_usd DESC
LIMIT 20;
```

```sql
-- Tỷ lệ chi phí đã được tag – theo dõi hằng tháng
SELECT
    month,
    ROUND(100.0 * SUM(CASE WHEN resource_tags_user_cost_center <> ''
                           THEN line_item_unblended_cost ELSE 0 END)
              / NULLIF(SUM(line_item_unblended_cost), 0), 1) AS tagged_pct
FROM acme_cur_hourly
WHERE year = '2026'
GROUP BY month
ORDER BY month;
```

Query cuối là **chỉ số cần theo dõi**. Mục tiêu thực tế: 90–95%. Đừng đặt 100% — luôn có chi phí không gắn được tag (mục 11).

Tự động hoá: Lambda chạy ngày mồng 3 hằng tháng, chạy ba query trên, render HTML rồi gửi email cho từng team lead qua SES.

---

## 11. Những chi phí không tag được

Kể cả tag hoàn hảo, một phần hoá đơn vẫn không quy về team nào:

| Loại chi phí | Vì sao | Cách xử lý |
|---|---|---|
| Data transfer giữa AZ/region | Không gắn với resource cụ thể | Split charge theo tỷ lệ |
| AWS Support | Tính theo % hoá đơn cả org | Split charge `PROPORTIONAL` |
| Thuế, phí | Ở mức account | Để trong `Unallocated` |
| NAT Gateway, Transit Gateway | Hạ tầng dùng chung | Cost Category `Platform` + split charge |
| CloudTrail, Config, GuardDuty | Bắt buộc, toàn org | Coi là chi phí nền tảng, split charge |
| Savings Plans / RI | Giảm giá áp chéo account | Dùng `line_item_unblended_cost` cho chargeback, `amortized` cho phân tích |

Cách làm thực tế: đưa toàn bộ nhóm này vào Cost Category `Platform`, rồi `split_charge_rule` chia về các BU theo tỷ lệ chi tiêu (mục 8). Team nào dùng nhiều thì gánh phần hạ tầng chung nhiều hơn — công bằng và dễ giải thích.

---

## 12. Kiểm tra

```bash
# 1. Tag policy đang attach ở đâu
aws organizations list-policies --filter TAG_POLICY
aws organizations list-targets-for-policy --policy-id p-xxxxxxxx

# 2. Báo cáo tuân thủ tag toàn org (chạy ở management account)
aws resourcegroupstaggingapi get-compliance-summary \
  --target-id-filters ou-xxxx-xxxxxxxx \
  --group-by TARGET_ID

# 3. Cost allocation tag đã Active chưa
aws ce list-cost-allocation-tags --status Active \
  --query 'CostAllocationTags[].[TagKey,Status]' --output table

# 4. Chi phí tháng trước theo CostCenter
aws ce get-cost-and-usage \
  --time-period Start=2026-07-01,End=2026-08-01 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=TAG,Key=CostCenter \
  --query 'ResultsByTime[0].Groups[].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table

# 5. Cost Category đã phân loại đúng chưa
aws ce get-cost-and-usage \
  --time-period Start=2026-07-01,End=2026-08-01 \
  --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=COST_CATEGORY,Key=BusinessUnit

# 6. Test SCP: tạo EC2 không tag phải bị chặn
aws ec2 run-instances --image-id ami-xxxxx --instance-type t3.micro \
  --profile app-dev
# An error occurred (UnauthorizedOperation) ... explicit deny in a service control policy

# 7. Resource không tuân thủ
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name required-tags --compliance-types NON_COMPLIANT
```

Lệnh 6 là bài test quan trọng nhất — nếu nó **không** bị chặn thì SCP chưa ăn.

---

## 13. Bẫy hay gặp

| Vấn đề | Nguyên nhân | Cách xử lý |
|---|---|---|
| Tag policy không chặn ai cả | Tag policy chỉ chuẩn hoá, không bắt buộc | Cần SCP (mục 5) |
| Bật cost allocation tag mà Cost Explorer trống | Chờ ~24h; và không hồi tố | Bật sớm ngay từ đầu |
| `costcenter` và `CostCenter` thành hai dòng riêng | AWS phân biệt hoa thường | `tag_key.@@assign` trong tag policy |
| Terraform diff lặp lại vô tận | `default_tags` xung đột với tag riêng của resource | Khai báo tường minh + `ignore_changes` trên `tags_all` |
| Resource cũ không có tag | Tag không tự áp ngược | Script backfill bằng `resourcegroupstaggingapi tag-resources` |
| SCP chặn cả Terraform pipeline | Pipeline tạo resource chưa kịp gắn tag | `default_tags` phải có trước khi bật SCP |
| Đổi tên tag key làm mất lịch sử | Chi phí gắn với key cũ | Coi tag key là bất biến |
| `Unallocated` chiếm tỷ trọng lớn | Nhiều chi phí không tag được | Bình thường 5–10%; cao hơn thì soi query mục 10.1 |
| Vượt giới hạn số tag trên resource | AWS giới hạn 50 tag/resource | Giữ danh sách bắt buộc ngắn |
| Team phàn nàn bị chặn deploy | Bật SCP ở prod trước | Roll out Sandbox → NonProd → Prod |

---

## 14. Lộ trình triển khai

Thứ tự này giảm thiểu số lần team bị chặn giữa chừng:

```text
Tuần 1  Chốt chuẩn tag, thêm default_tags vào mọi Terraform module
        Bật cost allocation tag NGAY (vì không hồi tố)

Tuần 2  Bật AWS Config rule required-tags ở chế độ theo dõi
        Chạy query mục 10.1, gửi danh sách resource thiếu tag cho từng team

Tuần 3  Backfill tag cho resource cũ (script + phối hợp với team)
        Theo dõi tỷ lệ tagged_pct tăng lên

Tuần 4  Attach tag policy vào OU Sandbox
        Attach SCP require-tags vào OU Sandbox

Tuần 6  Mở rộng tag policy + SCP lên OU NonProd

Tuần 8  Mở rộng lên OU Prod
        Dựng Cost Category + split charge rule
        Bật budget theo cost center

Tuần 10 CUR + Athena + báo cáo chargeback hằng tháng tự động
```

Việc quan trọng nhất nằm ở **tuần 1**: bật cost allocation tag. Nó không tốn gì, không rủi ro, và nếu quên thì mọi dữ liệu chi phí từ giờ tới lúc nhớ ra đều không chia theo tag được.

---

## 15. Hướng mở rộng

- **Infracost trên PR**: ước tính chi phí thay đổi ngay trong pull request, dùng chung pipeline ở [doc 10](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md).
- **Tự dọn sandbox**: Lambda quét tag `ExpiresAt`, dừng/xoá resource quá hạn — tiết kiệm thấy rõ ở OU Sandbox.
- **Rightsizing tự động**: Compute Optimizer + báo cáo gửi kèm chargeback hằng tháng, để team thấy chi phí đi kèm gợi ý cắt giảm.
- **Savings Plans**: khi đã có dữ liệu tag ổn định vài tháng, phân tích commitment phù hợp cho phần workload chạy đều.
- **FinOps dashboard**: QuickSight đọc CUR trong Athena, mỗi team một dashboard lọc sẵn theo `CostCenter` của họ.
