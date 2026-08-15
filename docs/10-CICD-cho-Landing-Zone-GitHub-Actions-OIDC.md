# CI/CD cho Landing Zone – GitHub Actions + OIDC, không dùng access key

Ví dụ 10: Pipeline chạy Terraform cho [Landing Zone](./06-Aws-Landing-Zone.md) — `plan` tự động trên PR, `apply` phải qua approval, và **không có access key nào tồn tại ở đâu cả**.

---

## 1. Ba nguyên tắc

| Nguyên tắc | Cách thực hiện |
|---|---|
| **Không credential dài hạn** | GitHub OIDC → assume IAM role, token sống vài phút |
| **Quyền đọc và quyền ghi tách biệt** | Role `plan` chỉ read-only; role `apply` mới có quyền thay đổi |
| **Thay đổi tầng org phải có người duyệt** | GitHub Environment với required reviewers |

Vì sao chuyện này quan trọng hơn bình thường với LZ: pipeline này có quyền **AdministratorAccess trên management account**, tức là quyền cao nhất trong toàn tổ chức. Một access key rò rỉ ở đây không phải sự cố của một service — nó là sự cố của cả công ty.

OIDC loại bỏ hẳn vật thể có thể rò rỉ: không có secret nào trong GitHub, không có key nào để xoay vòng, không có gì để lộ trong log.

---

## 2. Kiến trúc

```text
┌──────────────┐
│ Dev mở PR    │
└──────┬───────┘
       │
       ▼
┌────────────────────────────────────────────────────────┐
│ Workflow: plan (chạy tự động, không cần duyệt)         │
│                                                        │
│  fmt → validate → tflint → checkov                     │
│         │                                              │
│         ▼                                              │
│  OIDC ──► AcmeLandingZonePlanRole  (ReadOnlyAccess)    │
│         │                                              │
│         ▼                                              │
│  terraform plan -out=tfplan (song song các layer)      │
│         │                                              │
│         ▼                                              │
│  conftest kiểm tra plan JSON                           │
│         │                                              │
│         ▼                                              │
│  Comment kết quả plan vào PR                           │
└────────────────────────────────────────────────────────┘
       │
       │ review + approve PR + merge vào main
       ▼
┌────────────────────────────────────────────────────────┐
│ Workflow: apply                                        │
│                                                        │
│  GitHub Environment "lz-production"                    │
│    ⏸  CHỜ required reviewers bấm Approve               │
│         │                                              │
│         ▼                                              │
│  OIDC ──► AcmeLandingZoneApplyRole (Administrator)     │
│         │                                              │
│         ▼                                              │
│  apply tuần tự: 0-bootstrap → 1-organization → …       │
└────────────────────────────────────────────────────────┘
```

Điểm cần chú ý: **Environment approval nằm sau khi merge**, không phải thay thế cho review PR. Hai cổng khác nhau — PR review kiểm tra *code đúng chưa*, Environment approval kiểm tra *có nên chạy lúc này không*.

---

## 3. Thiết lập OIDC provider và role

### 3.1. terraform/cicd/oidc.tf

```hcl
variable "github_org"  { default = "acme" }
variable "github_repo" { default = "aws-landing-zone" }

# Lấy thumbprint động thay vì hardcode
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]

  tags = { Name = "github-actions-oidc" }
}

########################
# Role cho PLAN – read-only, chạy tự động
########################

resource "aws_iam_role" "plan" {
  name                 = "AcmeLandingZonePlanRole"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"

      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Chỉ PR của đúng repo này
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:pull_request"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# terraform plan vẫn cần ghi state lock. Cấp đúng phần đó, không hơn.
resource "aws_iam_role_policy" "plan_state" {
  name = "state-access"
  role = aws_iam_role.plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::acme-lz-tfstate-*",
          "arn:aws:s3:::acme-lz-tfstate-*/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
        Resource = "arn:aws:dynamodb:*:*:table/acme-lz-tflock"
      },
      # Đọc cấu hình ở account con để plan chính xác
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/AcmeLandingZoneReadOnlyRole"
      }
    ]
  })
}

########################
# Role cho APPLY – quyền cao, chỉ chạy sau approval
########################

resource "aws_iam_role" "apply" {
  name                 = "AcmeLandingZoneApplyRole"
  max_session_duration = 7200

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"

      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"

          # Khoá chặt vào ĐÚNG environment. Không dùng StringLike ở đây.
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:environment:lz-production"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arns" {
  value = {
    plan  = aws_iam_role.plan.arn
    apply = aws_iam_role.apply.arn
  }
}
```

### 3.2. Điều kiện `sub` – chỗ dễ mở toang cửa nhất

Đây là phần quan trọng nhất của cả bài. Trust policy sai một chỗ là bất kỳ ai trên GitHub cũng assume được role admin của bạn.

| Điều kiện `sub` | Ai dùng được | Đánh giá |
|---|---|---|
| `repo:acme/aws-landing-zone:environment:lz-production` | Chỉ job chạy trong environment đó | ✅ Dùng cho apply |
| `repo:acme/aws-landing-zone:pull_request` | Mọi PR của repo này | ✅ Chấp nhận cho plan read-only |
| `repo:acme/aws-landing-zone:ref:refs/heads/main` | Mọi job trên nhánh main | ⚠️ Không có cổng approval |
| `repo:acme/*` | **Mọi repo trong org** | ❌ Quá rộng |
| `repo:*` | **Bất kỳ ai trên GitHub** | ❌❌ Thảm hoạ |

Hai quy tắc: **luôn có điều kiện `aud`** (thiếu nó là lỗ hổng nghiêm trọng), và **role apply dùng `StringEquals` với environment**, không dùng `StringLike`.

Vì sao khoá theo `environment` chứ không phải branch: environment mới là thứ có **required reviewers**. Khoá theo branch thì bất kỳ workflow nào chạy trên `main` cũng lấy được quyền admin, kể cả workflow do người khác thêm vào sau này.

### 3.3. Cấu hình phía GitHub

*Settings → Environments → New environment: `lz-production`*

- **Required reviewers**: 2 người trong platform team
- **Wait timer**: 0 (reviewer đã là cổng đủ)
- **Deployment branches**: chỉ `main`

Thêm cả environment `lz-plan` không có reviewer, dùng cho workflow plan nếu muốn tách rõ.

---

## 4. Workflow plan

### 4.1. .github/workflows/terraform-plan.yml

```yaml
name: Terraform Plan

on:
  pull_request:
    branches: [main]
    paths:
      - '**.tf'
      - '**.tfvars'
      - 'accounts/**'
      - '.github/workflows/terraform-*.yml'

# Quyền tối thiểu. id-token bắt buộc cho OIDC.
permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  AWS_REGION: ap-southeast-1
  TF_VERSION: "1.9.5"

concurrency:
  group: lz-plan-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  lint:
    name: Lint và security scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3.1.2
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: terraform fmt
        run: terraform fmt -check -recursive -diff

      - name: tflint
        uses: terraform-linters/setup-tflint@19a52fbac37dacb22a09518e4ef6ee234f2d4987 # v4.0.0
      - run: tflint --recursive

      - name: Checkov
        uses: bridgecrewio/checkov-action@38a95e98d734de90a74defd3accb8d2fca8c4910 # v12
        with:
          directory: .
          framework: terraform
          soft_fail: false
          skip_check: CKV_AWS_144  # S3 cross-region replication: khong ap dung cho LZ

  plan:
    name: Plan ${{ matrix.layer }}
    needs: lint
    runs-on: ubuntu-latest

    strategy:
      fail-fast: false
      matrix:
        layer:
          - 0-bootstrap
          - 1-organization
          - 2-logging
          - 3-security
          - 4-identity-center
          - 5-network
          - 6-dns

    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - name: Bo qua layer khong doi
        id: changed
        run: |
          if git diff --quiet origin/${{ github.base_ref }} -- "${{ matrix.layer }}/"; then
            echo "skip=true" >> "$GITHUB_OUTPUT"
          else
            echo "skip=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Lay credential qua OIDC
        if: steps.changed.outputs.skip == 'false'
        uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: arn:aws:iam::111111111111:role/AcmeLandingZonePlanRole
          role-session-name: gha-plan-${{ github.run_id }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3.1.2
        if: steps.changed.outputs.skip == 'false'
        with:
          terraform_version: ${{ env.TF_VERSION }}
          terraform_wrapper: false

      - name: Terraform plan
        if: steps.changed.outputs.skip == 'false'
        id: plan
        working-directory: ${{ matrix.layer }}
        run: |
          terraform init -input=false
          terraform validate
          terraform plan -input=false -no-color -out=tfplan | tee plan.txt
          terraform show -json tfplan > plan.json

      - name: Kiem tra policy (conftest)
        if: steps.changed.outputs.skip == 'false'
        working-directory: ${{ matrix.layer }}
        run: |
          curl -sSL https://github.com/open-policy-agent/conftest/releases/download/v0.56.0/conftest_0.56.0_Linux_x86_64.tar.gz \
            | tar xz conftest
          ./conftest test plan.json --policy ../policy/ --all-namespaces

      - name: Comment ket qua vao PR
        if: steps.changed.outputs.skip == 'false'
        uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea # v7.0.1
        with:
          script: |
            const fs = require('fs');
            let plan = fs.readFileSync('${{ matrix.layer }}/plan.txt', 'utf8');

            // Comment GitHub gioi han 65536 ky tu
            const MAX = 60000;
            if (plan.length > MAX) {
              plan = plan.slice(0, MAX) + '\n\n... (cat bot, xem full o job log)';
            }

            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `### Plan: \`${{ matrix.layer }}\`\n\n<details><summary>Xem chi tiet</summary>\n\n\`\`\`hcl\n${plan}\n\`\`\`\n\n</details>`
            });
```

Vì sao pin action theo SHA thay vì tag: tag `v4` có thể bị đẩy sang commit khác bất cứ lúc nào. Với pipeline nắm quyền admin toàn org, một action bị chiếm quyền là đường vào trực tiếp. Dùng Dependabot để cập nhật SHA có kiểm soát.

### 4.2. Fork PR – GitHub đã chặn sẵn

PR từ fork **không lấy được OIDC token** (GitHub cấp `GITHUB_TOKEN` read-only và không phát hành id-token cho fork). Job plan sẽ fail ở bước lấy credential — đó là hành vi đúng, đừng "sửa" nó.

Tuyệt đối **không** dùng `pull_request_target` để lách. Trigger đó chạy code của workflow ở nhánh base nhưng với ngữ cảnh có quyền, và là một trong những lỗ hổng CI phổ biến nhất.

---

## 5. Policy as code – chặn thay đổi nguy hiểm

### 5.1. policy/landing-zone.rego

```rego
package main

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# Không được xoá AWS account
deny contains msg if {
    rc := input.resource_changes[_]
    rc.type == "aws_organizations_account"
    "delete" in rc.change.actions
    msg := sprintf("CHAN: khong duoc xoa account '%s'. Dong account phai lam thu cong.", [rc.address])
}

# SCP attach vào ROOT ảnh hưởng toàn tổ chức
deny contains msg if {
    rc := input.resource_changes[_]
    rc.type == "aws_organizations_policy_attachment"
    "create" in rc.change.actions
    startswith(rc.change.after.target_id, "r-")
    msg := sprintf("CHAN: '%s' attach SCP vao ROOT. Tach thanh PR rieng, gan nhan 'org-wide'.", [rc.address])
}

# Không được xoá/tắt CloudTrail
deny contains msg if {
    rc := input.resource_changes[_]
    rc.type == "aws_cloudtrail"
    "delete" in rc.change.actions
    msg := sprintf("CHAN: khong duoc xoa CloudTrail '%s'.", [rc.address])
}

# Bucket log không được để public
deny contains msg if {
    rc := input.resource_changes[_]
    rc.type == "aws_s3_bucket_public_access_block"
    rc.change.after.block_public_acls == false
    msg := sprintf("CHAN: '%s' tat block_public_acls.", [rc.address])
}

# IAM policy có Action "*" trên Resource "*"
deny contains msg if {
    rc := input.resource_changes[_]
    rc.type in ["aws_iam_role_policy", "aws_iam_policy"]
    doc := json.unmarshal(rc.change.after.policy)
    stmt := doc.Statement[_]
    stmt.Effect == "Allow"
    stmt.Action == "*"
    stmt.Resource == "*"
    msg := sprintf("CHAN: '%s' cap Action:* tren Resource:*.", [rc.address])
}

# Cảnh báo (không chặn) khi xoá nhiều resource một lúc
warn contains msg if {
    deletes := [rc | rc := input.resource_changes[_]; "delete" in rc.change.actions]
    count(deletes) > 10
    msg := sprintf("CANH BAO: plan nay xoa %d resource. Xem ky truoc khi approve.", [count(deletes)])
}
```

Kiểm tra policy trên plan JSON bắt được đúng loại lỗi mà `terraform validate` bỏ qua: cú pháp hợp lệ, nhưng **hệ quả** thì không chấp nhận được.

---

## 6. Workflow apply

### 6.1. .github/workflows/terraform-apply.yml

```yaml
name: Terraform Apply

on:
  push:
    branches: [main]
    paths:
      - '**.tf'
      - '**.tfvars'
      - 'accounts/**'
  workflow_dispatch:
    inputs:
      layer:
        description: 'Chi apply mot layer (de trong = tat ca)'
        required: false
        type: string

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ap-southeast-1
  TF_VERSION: "1.9.5"

# Không bao giờ apply song song hai lần
concurrency:
  group: lz-apply
  cancel-in-progress: false

jobs:
  apply:
    name: Apply Landing Zone
    runs-on: ubuntu-latest

    # Cổng approval nằm ở đây
    environment:
      name: lz-production

    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - name: Lay credential qua OIDC
        uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: arn:aws:iam::111111111111:role/AcmeLandingZoneApplyRole
          role-session-name: gha-apply-${{ github.run_id }}
          aws-region: ${{ env.AWS_REGION }}

      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3.1.2
        with:
          terraform_version: ${{ env.TF_VERSION }}
          terraform_wrapper: false

      # Apply TUẦN TỰ – layer sau phụ thuộc output của layer trước
      - name: Apply theo thu tu
        run: |
          set -euo pipefail

          LAYERS=(
            0-bootstrap
            1-organization
            2-logging
            3-security
            4-identity-center
            5-network
            6-dns
          )

          if [[ -n "${{ inputs.layer }}" ]]; then
            LAYERS=("${{ inputs.layer }}")
          fi

          for layer in "${LAYERS[@]}"; do
            echo "::group::Apply ${layer}"

            terraform -chdir="${layer}" init -input=false

            # -parallelism=1 cho layer tao account: tranh throttling Organizations
            EXTRA=""
            if [[ "${layer}" == "1-organization" ]]; then
              EXTRA="-parallelism=1"
            fi

            terraform -chdir="${layer}" apply -input=false -auto-approve ${EXTRA}

            echo "::endgroup::"
          done

      - name: Baseline cho cac account moi
        run: ./ci/apply-account-baselines.sh

      - name: Bao ket qua ve Jira
        if: always()
        env:
          JIRA_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
        run: ./ci/notify-jira.sh "${{ job.status }}"
```

`-auto-approve` ở đây không phải là bỏ qua kiểm duyệt — plan đã được review trong PR, và Environment approval đã có người bấm. Người duyệt là con người ở hai cổng trước đó, không phải prompt của Terraform.

### 6.2. Vì sao apply tuần tự mà plan song song

Plan chỉ đọc, chạy song song thoải mái. Apply thì layer sau cần output của layer trước (`1-organization` sinh account ID cho `2-logging` dùng), nên bắt buộc tuần tự. `concurrency: cancel-in-progress: false` đảm bảo hai lần merge sát nhau không apply chồng lên nhau — cực kỳ quan trọng với state file.

---

## 7. Phát hiện drift

Có người sửa tay trên console là chuyện chắc chắn sẽ xảy ra. Bắt sớm bằng workflow chạy định kỳ:

```yaml
name: Drift Detection

on:
  schedule:
    - cron: '0 22 * * *'   # 05:00 giờ VN hằng ngày
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  issues: write

jobs:
  detect:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        layer: [1-organization, 2-logging, 3-security, 4-identity-center, 5-network, 6-dns]

    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - uses: aws-actions/configure-aws-credentials@e3dd6a429d7300a6a4c196c26e071d42e0343502 # v4.0.2
        with:
          role-to-assume: arn:aws:iam::111111111111:role/AcmeLandingZonePlanRole
          role-session-name: gha-drift-${{ github.run_id }}
          aws-region: ap-southeast-1

      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3.1.2
        with:
          terraform_version: "1.9.5"
          terraform_wrapper: false

      - name: Plan phat hien drift
        id: drift
        working-directory: ${{ matrix.layer }}
        continue-on-error: true
        run: |
          terraform init -input=false
          terraform plan -input=false -no-color -detailed-exitcode > drift.txt 2>&1
          echo "exitcode=$?" >> "$GITHUB_OUTPUT"

      # exit 0 = khop, 1 = loi, 2 = co drift
      - name: Mo issue khi co drift
        if: steps.drift.outputs.exitcode == '2'
        uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea # v7.0.1
        with:
          script: |
            const fs = require('fs');
            const drift = fs.readFileSync('${{ matrix.layer }}/drift.txt', 'utf8').slice(0, 60000);
            const title = `Drift: ${{ matrix.layer }}`;

            const existing = await github.rest.issues.listForRepo({
              owner: context.repo.owner,
              repo: context.repo.repo,
              state: 'open',
              labels: 'drift'
            });

            if (existing.data.some(i => i.title === title)) {
              console.log('Issue drift da ton tai, bo qua.');
              return;
            }

            await github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title,
              labels: ['drift', 'landing-zone'],
              body: `Phat hien drift o \`${{ matrix.layer }}\`.\n\n\`\`\`\n${drift}\n\`\`\``
            });
```

`-detailed-exitcode` trả về `2` khi có thay đổi — đây là cách chuẩn để script phân biệt "không có gì đổi" với "có drift", thay vì đi grep chuỗi output.

---

## 8. Bảo mật pipeline

| Rủi ro | Cách chặn |
|---|---|
| Action bị chiếm quyền | Pin theo commit SHA, không dùng tag |
| Workflow mới lấy được role apply | Trust policy khoá theo `environment`, không theo branch |
| Fork PR lấy credential | GitHub đã chặn; không dùng `pull_request_target` |
| Sửa workflow để bỏ approval | Branch protection + CODEOWNERS cho `.github/workflows/` |
| Secret lộ trong log | Không có secret nào để lộ (đó là điểm của OIDC) |
| Apply chồng nhau | `concurrency` group không cancel |
| Người có quyền push thẳng lên main | Branch protection: bắt buộc PR, cấm force push |

### 8.1. .github/CODEOWNERS

```text
# Thay đổi pipeline hoặc tầng org cần platform team duyệt
/.github/workflows/   @acme/platform-team
/policy/              @acme/platform-team
/1-organization/      @acme/platform-team
/terraform/cicd/      @acme/platform-team

# Request account chỉ cần một người trong platform duyệt
/accounts/            @acme/platform-team
```

### 8.2. Giới hạn quyền của role apply

`AdministratorAccess` là mặc định tiện nhưng rộng. Khi pipeline đã ổn định, thay bằng policy có deny rõ ràng:

```hcl
resource "aws_iam_role_policy" "apply_guardrails" {
  name = "pipeline-guardrails"
  role = aws_iam_role.apply.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDestructiveOrgActions"
        Effect = "Deny"
        Action = [
          "organizations:CloseAccount",
          "organizations:DeleteOrganization",
          "organizations:RemoveAccountFromOrganization",
          "organizations:LeaveOrganization",
        ]
        Resource = "*"
      },
      {
        Sid      = "DenyTouchingOwnRole"
        Effect   = "Deny"
        Action   = ["iam:DeleteRole", "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy"]
        Resource = aws_iam_role.apply.arn
      },
      {
        Sid    = "DenyDeleteLogInfrastructure"
        Effect = "Deny"
        Action = [
          "cloudtrail:DeleteTrail",
          "cloudtrail:StopLogging",
          "s3:DeleteBucket",
        ]
        Resource = "*"
      }
    ]
  })
}
```

Deny statement thắng mọi Allow, kể cả `AdministratorAccess`. Pipeline vẫn làm được mọi việc thường ngày nhưng không thể tự huỷ hạ tầng log hay tự sửa trust policy của chính nó.

---

## 9. Kiểm tra

```bash
# 1. OIDC provider đã tạo
aws iam list-open-id-connect-providers

# 2. Xem trust policy của role apply – kiểm tra điều kiện sub và aud
aws iam get-role --role-name AcmeLandingZoneApplyRole \
  --query 'Role.AssumeRolePolicyDocument' | jq

# 3. Tìm dấu vết access key còn sót (phải trả về rỗng)
aws iam list-users --query 'Users[].UserName' --output text | \
  xargs -r -n1 aws iam list-access-keys --user-name

# 4. Ai đã assume role apply gần đây
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 20 \
  --query 'Events[].{Time:EventTime,User:Username}' --output table

# 5. Test conftest tại máy trước khi push
terraform -chdir=1-organization plan -out=tfplan
terraform -chdir=1-organization show -json tfplan > plan.json
conftest test plan.json --policy policy/ --all-namespaces
```

Lệnh số 3 là bài kiểm tra quan trọng nhất: sau khi chuyển sang OIDC, **không nên còn IAM user nào có access key** trong management account. Còn sót cái nào là còn một đường vào không qua pipeline.

---

## 10. Bẫy hay gặp

| Triệu chứng | Nguyên nhân |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | `sub` trong trust policy không khớp; xem `sub` thật ở job log |
| Lỗi trên nhưng chỉ ở workflow apply | Thiếu `environment:` trong job — không có nó thì `sub` không chứa `environment:` |
| `Credentials could not be loaded` | Thiếu `permissions: id-token: write` |
| Plan fail ở bước lock state | Role plan thiếu quyền DynamoDB trên bảng lock |
| Apply chồng nhau, state lỗi | Thiếu `concurrency` group |
| Comment plan bị cắt | Vượt 65536 ký tự — cắt bớt như mục 4.1 |
| Layer `1-organization` timeout | Tạo nhiều account cùng lúc; dùng `-parallelism=1` |
| Drift báo giả mỗi ngày | Attribute AWS tự đổi (ví dụ `role_name`); thêm `ignore_changes` |
| Checkov fail hàng loạt lúc mới bật | Bật `soft_fail: true` trước, siết dần |

---

## 11. Hướng mở rộng

- **Terraform Cloud / Spacelift**: nếu muốn state management và policy engine dạng dịch vụ thay vì tự dựng S3 + conftest.
- **Atlantis**: comment `atlantis apply` ngay trong PR, hợp với team quen workflow GitOps.
- **Infracost**: comment chi phí ước tính của mỗi PR — rất hợp với [11 – Tag Policy và Cost Allocation](./11-Tag-Policy-va-Cost-Allocation.md).
- **OIDC cho cả workload**: cùng cơ chế này áp cho pipeline deploy ứng dụng (ví dụ 01–05), mỗi repo một role riêng trong account tương ứng.
- **Ephemeral test org**: workflow nightly dựng một AWS Organization sandbox từ đầu, chạy toàn bộ LZ, verify, rồi xoá — bài kiểm tra thật sự cho code LZ.
