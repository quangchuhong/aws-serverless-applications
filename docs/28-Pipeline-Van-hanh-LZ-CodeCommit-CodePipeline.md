# Pipeline vận hành LZ — CodeCommit, CodePipeline, và sáu lớp kiểm

[Doc 10](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) là thiết kế CI/CD bằng GitHub Actions + OIDC. Tài liệu này là thứ **đã dựng thật**, và nó không phải doc 10: chính sách công ty không cho GitHub làm bề mặt điều khiển, nên toàn bộ đường tự động nằm trong AWS — CodeCommit, CodePipeline, CodeBuild. Repo GitHub vẫn tồn tại như một bản sao để đọc và review, nhưng **nó không kích hoạt gì cả**.

Code: [`modules/tf-pipeline/`](../modules/tf-pipeline/) (module dùng chung), [`landing-zone/ops-pipeline*/`](../landing-zone/) (năm caller), [`landing-zone/ops-gate/`](../landing-zone/ops-gate/) (cổng chặn).

> **Sơ đồ tổng quan:** [Luồng pipeline Landing Zone](https://claude.ai/code/artifact/efa04c8c-f8a3-4cae-9a97-250e75fdd1f9) — năm hình vẽ: đường kích hoạt, khung một pipeline với sáu lớp kiểm đặt đúng chỗ chúng chạy, phân bổ năm pipeline sang bốn account, vòng bốn nhịp nới lỏng, và đường drift. Đọc hình trước nếu bạn mới vào; các mục dưới đây là phần chi tiết của chính năm hình đó.

---

## 0. Trạng thái

| | |
|---|---|
| **Pipeline** | **5 pipeline, 8 stage, đã chạy thật** — mọi pipeline đã đi hết vòng Nguồn → Lint → Plan → Apply → Verify |
| **Module** | `modules/tf-pipeline` — 30 biến, 10 output, 4 buildspec template |
| **Cổng chặn** | `gate.py` — 37 loại resource có luật chiều NỚI/THẮT, 8 stage trong bảng phạm vi |
| **Verify** | 5 script đọc **AWS**, không đọc state; dùng chung `kiem-log.sh` |
| **Bộ kiểm offline** | `kiem-module.py` 18 phép kiểm · `test-gate.py` 43 test · `test-loc.py` 39 test |
| **Chưa** | Đường báo drift chưa ai đi thử thật · firewall còn `alert` · `tu_kich_hoat = true` ở ops-network |

Các lỗi gặp khi dựng lớp này ghi ở [doc 22](./22-Nhat-ky-Trien-khai-LZ-DIY.md). Mục 8.4 dưới đây tóm bảy cái đắt nhất, vì chúng nói về **cách đọc** chứ không chỉ về một dòng code.

---

## 1. Vì sao không phải GitHub Actions

Doc 10 vẫn là một thiết kế đúng, và nếu chính sách khác thì nó là lựa chọn tốt hơn: ít hạ tầng hơn, review và pipeline cùng một chỗ. Nó bị loại vì một lý do không kỹ thuật — **GitHub không được tính là bề mặt điều khiển nội bộ**. Hệ quả kỹ thuật thì có thật và phải ghi ra, vì chúng đổi cách vận hành:

| | GitHub Actions (doc 10) | CodePipeline (thực tế) |
|---|---|---|
| Kích hoạt | push/PR | CodeCommit event → Lambda lọc → StartPipelineExecution |
| Nơi thấy diff của một thay đổi | PR | **không có** — phải đọc `git log` hoặc bản plan |
| Review trước khi chạy | PR review | không có; duyệt xảy ra **giữa** plan và apply |
| Credential | OIDC, token vài phút | IAM role của CodeBuild |
| Nơi tfvars sống | secret của repo | **S3**, vì tfvars nằm trong `.gitignore` |

Điều đáng nhớ nhất trong bảng đó là dòng thứ hai. Không có PR nghĩa là **không có chỗ nào tự nhiên để một thay đổi bị đọc bởi người thứ hai**. Đó là lý do cơ chế nới lỏng (mục 5) đòi ghi `ticket / reason / approved_by` vào một file trong repo: file đó là thứ thay thế cho diff của PR.

Và hệ quả thực dụng nhất: **hai remote là hai bản sao.**

```bash
git push origin  <branch>      # GitHub — để đọc, để review, không kích hoạt gì
git push codecommit HEAD:main  # AWS — cái này mới chạy pipeline
```

Đẩy một bên rồi tưởng đã xong là lỗi hay gặp nhất của người mới vào repo này.

---

## 2. Kiến trúc — một sự kiện đi qua những gì

```
git push codecommit HEAD:main
   │
   ├─► CodeCommit "Repository State Change"  (referenceType=branch, referenceName=main)
   │      │
   │      │  Sự kiện này KHÔNG mang danh sách file. Chỉ có repositoryName,
   │      │  commitId, oldCommitId, referenceName.
   │      ▼
   │   EventBridge ─► Lambda  landing-zone/trigger-filter/lambda/loc.py
   │                    │   gọi GetDifferences(old, new) để biết file nào đổi
   │                    │   đối chiếu với ban_do: tiền tố → pipeline
   │                    ▼
   │                 StartPipelineExecution  chỉ những pipeline bị chạm
   │
   └─► (hoặc) rule EventBridge RIÊNG của từng pipeline — bắt MỌI commit
          Bật cả hai là hai đường cùng nổ. Xem mục 2.1.
```

### 2.1 Bộ lọc ở giữa, và vì sao nó phải tồn tại

Rule EventBridge của riêng một pipeline **không lọc được theo đường dẫn** — không phải vì viết sai, mà vì sự kiện không chứa danh sách file. Nên một dòng sửa trong `docs/` làm **cả năm** pipeline chạy, và mỗi cái park một phiếu duyệt.

`trigger-filter` là một Lambda đứng giữa: nó gọi `GetDifferences` để lấy danh sách file thật, rồi chỉ khởi động pipeline có tiền tố bị chạm.

```hcl
# landing-zone/trigger-filter/terraform.tfvars
ban_do = {
  "ops"                 = ["landing-zone/organization/"]
  "ops-trail"           = ["landing-zone/org-trail/"]
  "ops-permission-set"  = ["landing-zone/permission-sets/"]
  "ops-config-rules"    = ["landing-zone/config-detective/"]
  "ops-network"         = ["landing-zone/network/", "landing-zone/ops-gate/"]
}

tru = {
  # "landing-zone/network/" khớp CHUỖI nên nó bắt cả network/ops/.
  # Không có cách viết một tiền tố nghĩa là "network/ nhưng không network/ops/".
  "vending" = ["landing-zone/network/ops/"]
}
```

Bốn điểm dễ sai, cả bốn đều đã được `loc.py` kiểm mỗi lần chạy:

| Viết | Nghĩa |
|---|---|
| `"landing-zone/network/"` | đúng — có `/` nên không bắt `network-cu/` |
| `"landing-zone/network"` | bắt luôn `network-cu/...` |
| `""` | chạy với **mọi** thay đổi — hợp lệ, nhưng phải có chủ đích |
| `[]` | pipeline **không bao giờ chạy** — `loc.py` coi là lỗi cứng |

Dòng cuối đáng sợ nhất: một danh sách rỗng đọc giống "chưa điền" và chạy giống "đã tắt".

**Thứ tự bật, không đảo được:** bật `trigger-filter` trước, rồi mới đặt `tu_kich_hoat = false` ở từng pipeline. Làm ngược lại thì giữa hai lần apply không có gì kích hoạt pipeline nào — và đó là kiểu hỏng không có triệu chứng.

### 2.2 Năm pipeline, hai chủ sở hữu

Tách theo **chủ sở hữu**, không theo layer:

| Pipeline | Layer nó apply | Stage | Có cổng duyệt |
|---|---|---|---|
| `qh11-lz-ops` | `landing-zone/organization` | `sec-ou`, `sec-scp`, `sec-tagging` | — |
| `qh11-lz-ops-trail` | `landing-zone/org-trail` | `cloudops-trail` | — |
| `qh11-lz-ops-permission-set` | `landing-zone/permission-sets` | `cloudops-permission-set` | — |
| `qh11-lz-ops-config-rules` | `landing-zone/config-detective` | `cloudops-config-rules` | — |
| `qh11-lz-ops-network` | `landing-zone/network/ops` | `cloudops-network`, `cloudops-firewall` | `cloudops-firewall` |

Sec giữ guardrail ở `organization`; vận hành là việc của cloudops. Hai pipeline, hai role, hai luồng thông báo, hai nút re-run.

**Khoá stage phải duy nhất toàn cục** và mang tên chủ sở hữu (`sec-`, `cloudops-`), vì bảng `PHAM_VI` trong `gate.py` là **một bản dùng chung cho mọi pipeline**. Hai pipeline cùng có stage tên `ou` sẽ đè lên nhau trong bảng đó, và cái bị đè lặng lẽ nhận phạm vi của cái kia.

Sec chỉ review ở hai chỗ — code review, và duyệt trước apply — và chỉ cho SCP, permission set, firewall rule.

### 2.3 Một pipeline gồm những stage nào

```
Nguon      CodeCommit source
Lint       buildspec-catalog.yml  — KHÔNG Terraform, KHÔNG state, KHÔNG gọi AWS
Expiry     cùng project, MODE=expiry — mục catalog hết hạn
                                        (chặn hay chỉ báo: expiry_blocks_pipeline)
┌─ với MỖI stage trong local.stages ────────────────────────┐
│  <key>-Plan     buildspec-terraform.yml  TF_ACTION=plan   │
│  <key>-Duyet    approval  (chỉ stage trong approve_stages)│
│  <key>-Apply    buildspec-terraform.yml  TF_ACTION=apply  │
└───────────────────────────────────────────────────────────┘
Verify     buildspec-verify.yml — KHÔNG cài Terraform, KHÔNG đọc state, KHÔNG kéo tfvars
```

`Lint` đứng trước mọi thứ chạm AWS: một lỗi schema trong catalog dừng pipeline khi chưa có gì được gọi.

`Verify` nhận artifact **nguồn**, không nhận bản plan — nó không đọc kế hoạch, nó đọc thực tế.

### Một stage Plan/Apply làm gì, theo thứ tự

`buildspec-terraform.yml`, và mỗi bước là một chốt:

1. **Kéo `terraform.tfvars` từ S3** — `s3://<tfvars_bucket>/tfvars/<layer>/terraform.tfvars`.
   Thiếu file này là **lỗi cứng**. Không phải vì plan sẽ lỗi — mà vì nó sẽ **thành công**: mọi biến đều có mặc định, nên plan mô tả một tổ chức không có SCP.
2. **Sinh `backend.tf`** bằng `printf` (không heredoc — xem mục 8.4).
3. **`terraform init`** với `-backend-config` trỏ đúng khoá state.
4. **Đếm resource trong state.** `0` mà `FIRST_APPLY != yes` là lỗi cứng: state rỗng nghĩa là **sai khoá**, không phải lần chạy đầu.
5. **Lint của layer** nếu stage khai `lint`.
6. **`terraform plan -detailed-exitcode $TARGET_ARGS -out=tfplan`**.
7. **`gate.py`** đọc `tfplan.json`.
8. **`FAIL_ON_DESTROY`** đếm số resource bị xoá/thay thế.
9. Stage `apply` chạy đúng `tfplan` đã lưu, rồi `apply -refresh-only` để ghi lại output.

Bước 9 không phải cho đẹp. `terraform apply <file plan>` với `-target` **loại output khỏi plan** trừ khi output phụ thuộc vào resource được target — kết quả là state có resource mới nhưng output cũ. `-refresh-only` không đổi hạ tầng; nó đọc lại thực tế và ghi state, kể cả output.

---

## 3. Sáu lớp kiểm, và chúng không thấy nhau

Đây là phần quan trọng nhất của tài liệu. Mỗi lớp đọc một thứ khác nhau, và **không lớp nào thay được lớp khác**.

> `next_steps` của module vẫn in **"BỐN LỚP KIỂM"**. Câu đó đúng khi viết: `precondition` và `verify` chưa tồn tại. Nó là một con số sẽ lệch tiếp mỗi lần thêm lớp, nên đừng tin nó — bảng dưới đây là bảng đúng.

| Lớp | Đọc gì | Trả lời câu gì | Chạy ở đâu |
|---|---|---|---|
| `lint.sh` | catalog YAML, offline | Khai báo có hợp lệ không | stage Lint, và trên máy |
| `precondition` | local của Terraform | Khai báo có **mâu thuẫn nội bộ** không | trong plan của từng stage |
| `gate.py` | `tfplan.json` | Thay đổi này **nới** hay **thắt** | sau plan, mọi stage |
| Cổng duyệt | con người | Việc này **có nên** xảy ra không | giữa plan và apply |
| `FAIL_ON_DESTROY` | số dòng `will be destroyed` | Có xoá gì không | sau `gate.py` |
| `verify.sh` | **AWS**, không phải state | Thực tế có đúng như ta tưởng không | stage Verify, sau apply |

Lớp thứ tư là lớp **duy nhất** đọc được ý định. `gate.py` biết "tạo một assignment là nới"; chỉ con người biết "assignment này có nên tồn tại".

### 3.1 `gate.py` — chiều, không phải hành động

Cổng này không đếm. Nó đọc `before`/`after` của từng thuộc tính và biết chiều của từng dịch vụ:

```python
"aws_organizations_policy_attachment": {
    "xoa_la_noi": "một guardrail không còn gắn vào đâu - policy vẫn tồn tại nên nó trông như không có gì đổi",
},
"aws_ssoadmin_managed_policy_attachment": {
    "tao_la_noi": "gắn thêm một managed policy vào permission set - mọi người đang dùng set đó được thêm quyền ngay",
},
"aws_networkfirewall_rule_group": {
    "xoa_la_noi": "bỏ một nhóm luật tường lửa - lưu lượng trước đây bị chặn sẽ đi qua, và không có log nào nói rằng một luật vừa biến mất",
},
```

Hai chiều ngược trực giác, và cả hai đã gặp thật:

- **Tạo** một `aws_vpc_security_group_ingress_rule` là **nới** — mở một cửa.
- **Thêm** một account vào `excluded_accounts` của Config rule là **nới** — một tập **lớn lên** lại là nới lỏng, vì mỗi account thêm vào là một account thoát khỏi phép kiểm, và nó thoát trong im lặng: rule vẫn "đang bật", console vẫn xanh.

37 loại resource có luật. Loại không có trong bảng thì `gate.py` **bỏ qua hoàn toàn** (`luat is None → return []`) — đó là lựa chọn, và nó có nghĩa là mỗi resource mới đưa vào phạm vi một stage phải được cân nhắc xem có cần luật hay không.

### 3.2 `FAIL_ON_DESTROY` — thô nhất, và nới lỏng không cấp phép được cho nó

```hcl
# modules/tf-pipeline/codebuild.tf — trong project "terraform", dùng chung mọi stage
environment_variable {
  name  = "FAIL_ON_DESTROY"
  value = "yes"
}
```

Không có biến nào điều khiển nó, và `pipeline.tf` chỉ ghi đè `GATE_STAGE` theo stage. Nên nó áp cho **mọi stage của mọi pipeline**, và buildspec thoát 1 ngay ở bước *plan* khi thấy bất kỳ destroy nào.

Hai hệ quả phải biết trước khi cần xoá gì:

- **Xoá qua pipeline là không làm được.** Xoá một mục catalog sinh ra destroy → plan chết. Làm tay là đường duy nhất.
- **Khai nới lỏng không cứu được.** `loosen` chỉ nói chuyện với `gate.py`. `FAIL_ON_DESTROY` là một phép đếm trong shell chạy *sau* đó và không đọc file khai báo. Vòng bốn nhịp cấp phép cho *nới*, không cấp phép cho *xoá*.

> **Đã biết, chưa sửa:** thông báo ở chốt này ghi `pipeline nay KHONG co cong duyet, nen mot plan co xoa ... bi TU CHOI`. Câu đó đúng khi mới viết, nhưng `cloudops-firewall` **có** cổng duyệt và vẫn nhận đúng thông báo này — người đọc sẽ đi tìm một cổng duyệt không tồn tại. Sửa phải sửa `buildspec-terraform.yml`, tức apply lại toàn bộ layer pipeline kể cả `vending-pipeline`.

### 3.3 `precondition` — và vì sao nó từng vắng mặt suốt nhiều lần chạy

Một layer có thể đặt chốt cứng vào một `terraform_data`:

```hcl
resource "terraform_data" "catalog_guard" {
  input = { apps = length(local.apps_raw), rules = length(local.fw_raw), ... }

  lifecycle {
    precondition {
      condition = data.aws_caller_identity.current.account_id == local.hub.account_id
      ...
    }
    # ... 30 precondition nữa
  }
}
```

`precondition` mạnh hơn `check`: `check` chỉ **cảnh báo**, apply vẫn chạy tiếp; `precondition` làm **plan chết**. `input` tồn tại để buộc plan tính lại khi catalog đổi.

**Nhưng `precondition` chỉ được tính khi resource nằm trong plan.** Mọi stage đều `-target`, và `-target` kéo theo *phụ thuộc*, không kéo theo *cái phụ thuộc vào nó*. Trong repo có **0** `depends_on`, nên không gì lôi guard vào. Kết quả: **33 chốt** (31 ở `network/ops`, 2 ở `organization`) chỉ chạy khi một *người* gõ `terraform plan` đầy đủ, và **không chạy trên đường tự động** — đúng con đường apply mà không ai đọc bản plan.

Phát hiện bằng bằng chứng chứ không bằng suy luận: `input` của guard vẫn ghi `rules = 5` sau khi pipeline đã đẩy 7 dòng luật vào AWS thật.

Triệu chứng thứ hai, ăn mòn hơn: job drift chạy `plan` **không** `-target`, nên mỗi đêm nó báo layer lệch — vĩnh viễn, cho một thứ không ai sửa được qua pipeline. Một cảnh báo luôn kêu thì chẳng mấy sẽ không ai đọc.

Cách sửa: đưa guard vào phạm vi. Xem mục 4 — nó phải khai ở **hai** nơi.

---

## 4. Phạm vi của một stage khai ở HAI nơi

| Khai ở đâu | Trả lời câu gì | Thiếu thì sao |
|---|---|---|
| `targets` trong caller pipeline | resource có **vào** plan không | chốt im lặng, drift vĩnh viễn |
| `PHAM_VI` trong `gate.py` | resource có **được phép** đổi không | vào plan rồi bị cổng chặn, plan đỏ |

Hai vế hỏng theo hai kiểu khác nhau, và **sửa vế đầu làm lộ vế sau**. Đúng ra đó là cổng chặn làm việc của nó: nó thấy một resource ngoài phạm vi khai báo và từ chối; nó không có cách nào biết resource đó là chốt an toàn.

```python
# landing-zone/ops-gate/gate.py
"cloudops-network": [
    "terraform_data.catalog_guard",      # dạng ĐỊA CHỈ
    "aws_route53_record",                # dạng TYPE
    ...
],
```

Bảng nhận cả hai dạng. **Chốt an toàn phải khai dạng địa chỉ**: cho cả type `terraform_data` nghĩa là mọi `terraform_data` tương lai cũng qua được, kể cả một cái mang `provisioner` chạy lệnh cục bộ trong CodeBuild. Chốt an toàn được phép đi qua; một cái cổng thì không.

Dạng địa chỉ cũng là cách tách hai stage cùng type:

```
aws_organizations_policy.scp   →  stage sec-scp
aws_organizations_policy.tag   →  stage sec-tagging
```

Khớp theo type thì hai stage đó có phạm vi giống nhau, tức stage `tagging` được phép sửa SCP — đúng cái mà `PHAM_VI` tồn tại để chặn.

`kiem-module.py` phép kiểm 18 đối chiếu cả hai vế. Ban đầu nó chỉ đọc `targets`, tức nó báo xanh cho đúng cấu hình làm pipeline đỏ: **nửa phép kiểm là một phép kiểm nói rằng mọi thứ ổn.**

---

## 5. Cơ chế nới lỏng — vòng bốn nhịp

Khi `gate.py` thấy một thay đổi **nới**, nó chặn. Muốn đi qua thì phải khai, và khai báo đó là thứ thay cho diff của PR:

```yaml
# landing-zone/network/ops/ops-loosen.yaml
loosen:
  - stage: cloudops-firewall
    address: aws_vpc_security_group_ingress_rule.partner_service["sim-api-v2|172.16.0.0/16"]
    ticket: TEST-9002
    reason: mở dịch vụ api-v2 cho đối tác sim
    approved_by: ai@day.com
```

Trường `stage` **bắt buộc khi layer có từ hai stage**. `ops-loosen.yaml` là *một* file cho cả layer, nhưng `gate.py` chạy theo *từng* stage với một bản plan đã `-target`. Nên một khai báo cho stage A là "không dùng tới" dưới mắt stage B, và `--strict` biến cảnh báo đó thành một lần đỏ. Đã xảy ra thật: khai báo của `cloudops-firewall` giết stage `cloudops-network` dù bản plan của nó sạch.

**Vòng bốn nhịp, và nhịp bốn là cái bẫy:**

| Nhịp | Việc | Kết quả |
|---|---|---|
| 1 | push thay đổi nới | **chặn** |
| 2 | khai `loosen` + push | qua, apply được |
| 3 | **xoá khai báo** + push | qua — cửa đã đóng |
| 4 | quên xoá | lần chạy **sau** đỏ: "khai báo không dùng tới" |

Nhịp 4 là cố ý. Một cánh cửa để mở làm pipeline đỏ tự nó, chứ không chờ ai nhớ ra.

---

## 6. Verify — lớp đọc AWS, không đọc state

Bốn lớp trên đọc **khai báo**. Verify đọc **thực tế**. Khác biệt đó không hình thức: `terraform plan` ra `No changes` ở cả hai trạng thái "email đã bấm xác nhận" và "chưa bấm", nên state không trả lời được câu hỏi nào về việc cảnh báo có tới ai.

| Script | Layer | Đọc gì từ AWS |
|---|---|---|
| `organization/kiem-to-chuc.sh` | organization | SCP đang gắn thật, cây OU |
| `org-trail/kiem-trail.sh` | org-trail | trail, log validation, bucket |
| `permission-sets/kiem-quyen.sh` | permission-sets | assignment thật theo account |
| `config-detective/kiem-config.sh` | config-detective | org config rule, `excluded_accounts` |
| `network/kiem-mang.sh` | network/ops | rule group, `StatefulDefaultActions`, alarm, subscription |

`buildspec-verify.yml` **không cài Terraform, không đọc state, không kéo tfvars** — cố ý. Một script verify đọc tfvars sẽ so khai báo với khai báo.

### Ba lỗi thiết kế verify đã gặp, và cách tránh

**Đọc hỏng trả về rỗng, rồi rỗng được đọc thành câu trả lời.** `kiem-mang.sh` phân biệt rõ:

```python
if d is None:                      # không đọc được list-rule-groups
    if CHE_DO == "chua-dung":
        print("  Nên không kết luận được gì - KỂ CẢ chiều 'không có gì'.")
        sys.exit(0)
    loi.append("chế độ 'da-dung' mà không đọc được list-rule-groups. ...")
```

Điều kiện phân biệt phải là **phép đọc có thành công hay không**, không phải "có truyền ARN hay không". Assume từ bên trong chính account đích sẽ `AccessDenied` vì role chỉ tin management — một ARN có mặt không chứng minh gì.

**So với tfvars là so sai.** Tập loại trừ thật là `distinct(concat(var.excluded_accounts, local.vending_excluded))`, nên con số trong tfvars **luôn** nhỏ hơn ở AWS. Phép so đúng là `terraform output recording_scope`.

**Stage xanh không có nghĩa là không có gì.** `kiem-log.sh` đọc log của lần chạy vừa rồi qua `ListActionExecutions` + `GetLogEvents`, và nó tồn tại vì `check` block chỉ cảnh báo — một cảnh báo thật sống sót qua một pipeline hoàn toàn xanh. Nó phải:

- **bỏ ANSI escape** trước khi so khớp, nếu không mọi mẫu đều trượt;
- **lọc heredoc** — `terraform output` in ra văn bản tài liệu có chứa chữ `Warning:`, và văn bản tài liệu bị khớp như dữ liệu là bốn cửa khác nhau đã sập;
- **in được nội dung** assertion, không chỉ dòng `Check block assertion failed` trơ trọi.

> Một bộ lọc từng bị thêm vào để bỏ qua mọi thứ sau `Outputs:` — dựa trên giả định "cảnh báo in trước output". Giả định đó sai (một build có **hai** lần apply), và nó nuốt một cảnh báo thật. Chỉ phát hiện được bằng cách so hai con số tổng: 1711 = 1711.

### Verify cố ý không kiểm những gì

`kiem-mang.sh` in ra ba thứ nó **không** kiểm và lý do — vì một danh sách "đã kiểm" mà không nói phần còn lại thì đọc như "đã kiểm hết":

1. **Số luật so với catalog** — một mục `firewall-rules.yaml` có thể thành một dòng Suricata phủ nhiều port, nên hai số lệch nhau **hợp lệ**.
2. **Ingress rule của partner service** — cần security group id từ state layer cha; đó là việc của `verify.sh` trên máy.
3. **DNS record** — DNS sai có triệu chứng ngay; lớp này dành cho thay đổi **không** có triệu chứng.

---

## 7. Drift — phép kiểm có giá trị nhất, và nhánh chưa ai đi thử

Một CodeBuild riêng, chạy theo `drift_cron` (mặc định `cron(0 19 * * ? *)`). Nó **chỉ** `plan -lock=false`, và không có nhánh apply — không phải vì một biến được đặt đúng, mà vì **đoạn code apply không tồn tại**. Một biến có thể bị đè sai; một đoạn code không có thì không.

`-lock=false` là cố ý: bước này chạy theo lịch và có thể trùng với một lần apply thật. Một phép **kiểm** làm chặn một lần **sửa** là một phép kiểm gây ra sự cố.

Ba thứ nó phân biệt, và cái thứ ba hay bị gộp:

| Kết quả | Nghĩa |
|---|---|
| `SO_DRIFT` | layer có thay đổi ngoài Terraform |
| `SO_HONG` | layer **không kiểm được** — thiếu tfvars, sai khoá state |
| cả hai `0` | khớp |

Một layer thiếu tfvars không sinh ra dòng drift nào. Nếu chỉ đếm `SO_DRIFT` thì báo cáo nói "0 drift" cho một hệ thống **chưa hề được nhìn**. Đếm riêng, báo riêng.

Job thoát khác 0 khi có drift, để lần chạy hiện ra là **thất bại** trong console và mọi bảng theo dõi. Một job xanh mang tin xấu bên trong là một job không ai mở ra.

**Nhánh chưa ai đi thử.** Thứ tự trong buildspec là:

```sh
if [ "$SO_DRIFT" = "0" ] && [ "$SO_HONG" = "0" ]; then
  echo "Moi layer khop state."; exit 0        # ← thoát ở đây
fi
if [ -n "${DRIFT_TOPIC_ARN:-}" ]; then
  ... aws sns publish ...                     # ← chỉ chạy khi CÓ phát hiện
```

Nên chạy tay job drift trên một hệ thống sạch **không kiểm được gì** về đường SNS. Và khi nó chạy, thất bại là im lặng:

```sh
if aws sns publish ...; then echo "Da bao ve ..."
else echo "CANH BAO: khong bao duoc ve SNS - xem quyen sns:Publish"; fi
```

`else` không làm build đỏ.

### Hai cách khai đích báo, và vế thứ hai của SNS liên account

```hcl
drift_emails    = ["ai@day.com"]   # CHỌN MỘT: layer tự tạo topic ở chính account này
drift_topic_arn = ""               # HOẶC: dùng topic có sẵn — loại trừ với dòng trên
```

Khai **cả hai** thì `drift_topic_arn` thắng, topic tự tạo **không** được tạo, và những địa chỉ kia nhận số không. `check "khong_khai_ca_hai_nguon_topic"` có cảnh báo — nhưng `check` không bao giờ làm apply dừng.

Và `[""]` **không phải** `[]`: nó là danh sách có một phần tử rỗng, `length()` trả về 1. Tuỳ cấu hình mà nó im lặng hôm nay và nổ hôm sau. Từ nay 17 biến `*_emails` có `validation` chặn ở plan, và `kiem-module.py` phép kiểm 17 giữ chỗ đó.

Nếu dùng topic ở **account khác**: SNS liên account đòi **cả hai** phía cho phép. Quyền IAM của bên gửi là chưa đủ — resource policy của topic cũng phải cho:

```bash
aws sns get-topic-attributes --topic-arn <arn> --query 'Attributes.Policy' --output text \
  | python3 -m json.tool     # tìm AllowCrossAccountPublish
```

Và topic đó nằm ngoài tầm pipeline `ops-config-rules`: stage của nó `-target` vào đúng `aws_config_organization_managed_rule`, cố ý — *"một pipeline tự apply được chúng là một pipeline có thể tắt cả hệ thống phát hiện của tổ chức trong một lần chạy."* Thêm publisher là apply **tay**:

```bash
cd landing-zone/config-detective && terraform apply -target=aws_sns_topic_policy.alerts
```

---

## 8. Viết code một pipeline

### 8.1 Module và caller

`modules/tf-pipeline` (30 biến, 10 output) dựng toàn bộ: CodePipeline, 4 CodeBuild project, IAM role, artifact bucket, topic duyệt, job drift. Caller chỉ khai **cái gì** chạy, không khai **chạy thế nào**.

```hcl
# landing-zone/ops-pipeline-network/main.tf
locals {
  stages = [
    {
      key     = "cloudops-network"
      layer   = "landing-zone/network/ops"
      enabled = var.enable_network_stage

      targets = [
        "terraform_data.catalog_guard",   # chốt an toàn - mục 4
        "aws_route53_record.ops",
        ...
      ]

      khong_co_lint   = "network/ops không có catalog - phép kiểm ý nghĩa là gate.py"
      assume_role_arn = var.network_deploy_role_arn
      mo_ta           = "DNS record, endpoint, route, load balancer, alarm. Không có cổng duyệt - thay đổi sai ở đây có triệu chứng ngay."
    },
    ...
  ]
}

module "pipeline" {
  source = "../../modules/tf-pipeline"

  stages          = local.stages
  approve_stages  = var.approve_stages
  verify          = "./landing-zone/network/kiem-mang.sh '${var.network_deploy_role_arn}' ..."
  tfvars_bucket   = var.tfvars_bucket
  layer_keys      = var.layer_keys
  state_chi_doc   = ["demo-network-lz-full/terraform.tfstate"]
  ...
}
```

Bốn trường không được bỏ, mỗi cái vì một lý do đã trả giá:

| Trường | Bỏ thì sao |
|---|---|
| `khong_co_lint` / `lint` | một stage không lint **và** không giải thích là một stage chỉ còn `FAIL_ON_DESTROY`, tức chỉ còn phép đếm |
| `layer_keys` | **không có mặc định, cố ý.** Một mặc định ở đây là một cách sai khoá state mà không ai gõ sai gì |
| `state_chi_doc` | layer đọc state layer khác qua `terraform_remote_state` sẽ chết với `403 Forbidden` — và thông báo nói về S3, không nói về một phụ thuộc state chưa khai |
| `assume_role_arn` | provider không nhảy account; và nếu quên khai **trong type của biến** thì xem mục 8.4 |

### 8.2 tfvars nằm ở S3, không ở git

`tfvars` trong `.gitignore`, nên checkout không có nó. Pipeline kéo từ `s3://<bucket>/tfvars/<layer>/terraform.tfvars`, dùng chung kho với `vending-pipeline` — cố ý: hai kho là hai chỗ phải đẩy file, và một kho cũ là một bản plan **sai** mà không có lỗi nào.

```bash
cd landing-zone/vending-pipeline && ./push-tfvars.sh
```

Hai chỗ hay quên:

- **`push-tfvars.sh` có danh sách `LAYERS` gõ tay.** Thêm layer mới mà quên thêm vào đó thì không có lỗi lúc đẩy — chỉ có lỗi lúc pipeline chạy, và thông báo nói về S3 chứ không nói về script này. `kiem-module.py` phép kiểm 11 đối chiếu hai bên.
- **Đẩy tfvars lên S3 không kích hoạt pipeline.** EventBridge nghe CodeCommit, không nghe S3. Sửa tfvars thì phải `start-pipeline-execution` bằng tay.

### 8.3 Hai quy ước tên cùng tồn tại — và đó không phải lỗi

```
qh11-lz-…     các pipeline
quh11-lz-…    config-detective, billing-guard, network, bucket log của org-trail
```

Cả hai đều thật, suy ra từ `var.project` của **hai layer khác nhau**. "Sửa" `quh11-lz-security-findings` thành `qh11-lz-…` cho khớp pipeline sẽ làm publish thất bại lúc 2 giờ sáng. Và đổi `project` nghĩa là đổi tên resource, tức destroy + create — với `prevent_destroy` thì apply **thất bại**.

Lấy tên từ layer sở hữu nó, đừng gõ tay:

```bash
cd ../config-detective && terraform output alert_topic
```

### 8.4 Bảy cái bẫy đã sập, và cả bảy đều là về cách đọc

**1. Terraform âm thầm bỏ thuộc tính không khai trong type.**

```hcl
type = list(object({
  key = string
  # assume_role_arn không có ở đây
}))
```

Caller khai `assume_role_arn = "arn:..."` → **bỏ đi, không lỗi, không cảnh báo**. Rồi `try(stage.value.assume_role_arn, "")` biến cái thiếu thành `""` — hai lớp im lặng. Lỗi hiện ra ba lớp xa: `failed to get shared config profile, default`. Dấu hiệu thật là một dòng log **không xuất hiện** (`== provider se assume: ...`). Phép kiểm 13 đối chiếu mọi `stage.value.X` với type.

**2. `tu_kich_hoat = true` không phải "chạy hai lần", mà là "chạy với mọi push".** Rule riêng chỉ lọc `referenceName=main`; sự kiện không mang danh sách file.

**3. `-target` giới hạn apply, nhưng `plan` vẫn refresh toàn bộ state.** Nên role cần **đọc rộng, ghi hẹp**. Thiếu một quyền đọc mà không ai đoán trước làm cả plan chết, và thông báo không nhắc gì tới `-target`:

```
Error: reading CloudFormation StackSet (...): 403 AccessDenied
```

**4. `grep '^Plan:'` trên `tfplan.txt` không bao giờ khớp.** `terraform show <file plan>` không in dòng `Plan: N to add` — dòng đó do `terraform plan` in ra màn hình. Một lớp chặn chết im lặng từ ngày đầu. Đếm theo `will be created` / `will be updated in-place` / `will be destroyed`.

**5. Không dùng chuỗi nhiều dòng trong buildspec.** Nội dung của `- |` là YAML block scalar: một dòng thụt thấp hơn mức gốc **kết thúc block** ngay tại đó, và phần còn lại của script bị đọc như YAML. Thông báo lỗi trỏ tới một dòng cách đó ba mươi dòng, nói về `expected <block end>`. Nên báo cáo tích luỹ vào **một file**, không vào một biến nhiều dòng; và sinh `backend.tf` bằng `printf`, không bằng heredoc.

**6. Bộ kiểm tự đi qua chính nó.** Phép kiểm 14 tìm một chuỗi quyền IAM và **tìm thấy nó trong chú thích tôi vừa viết**. Phải bỏ dòng `#` trước khi tìm. Phép kiểm 18 cũng vậy, và ở đó đã thử đột biến đúng tình huống: gỡ dòng *thật* ở stage mà *chú thích* của nó có chứa chuỗi đó.

**7. `grep` của chính mình che mất traceback.** Ba lần. Một `UnboundLocalError` trong bộ kiểm bị ẩn vì mẫu grep chỉ bắt dòng kết quả.

---

## 9. Step by step — dựng một pipeline mới

Giả sử thêm pipeline cho một layer `landing-zone/vi-du`.

### 9.1 Trước khi viết dòng nào

```bash
cd landing-zone/tf-backend && terraform output layers      # khoá state của layer
cd ../vending-pipeline     && terraform output -raw tfvars_bucket
```

Hai giá trị đó là input, không phải thứ để gõ tay.

### 9.2 Tạo caller

```
landing-zone/ops-pipeline-vi-du/
  main.tf        local.stages + module block + quyền
  variables.tf   enable_*_stage, approve_stages, drift_*, …
  outputs.tf     module.pipeline.next_steps, drift_project, cong_duyet
  versions.tf
  terraform.tfvars.example
```

Trong `local.stages`, mỗi stage khai: `key` (duy nhất toàn cục, mang tiền tố chủ sở hữu), `layer`, `enabled`, `targets`, `lint` **hoặc** `khong_co_lint`, `mo_ta`, và `assume_role_arn` nếu layer đổi account.

### 9.3 Bốn chỗ phải khai, dễ quên ba

| Chỗ | Khai gì | Quên thì sao |
|---|---|---|
| `gate.py` → `PHAM_VI` | stage mới + phạm vi của nó | `gate.py` chỉ **cảnh báo** "stage không có trong bảng" — tức không kiểm được phạm vi mà vẫn xanh |
| `push-tfvars.sh` → `LAYERS` | layer mới | lỗi lúc pipeline chạy, thông báo nói về S3 |
| `trigger-filter` → `ban_do` | tiền tố → tên **ngắn** của pipeline | pipeline tồn tại, xanh trong console, và **không bao giờ chạy nữa** |
| `trigger-filter` → `tru` | nếu có layer lồng nhau | pipeline khác chạy vô ích, kèm một cổng duyệt treo mang nhãn sai |

Bật `kiem_do_phu = true` thì `loc.py` liệt kê pipeline thật ở AWS mỗi lần chạy và báo hỏng nếu có cái nào mang tiền tố `${project}-` mà không có trong bản đồ.

### 9.4 Chốt an toàn, nếu layer có

Layer có `terraform_data` mang `precondition` thì **mọi** stage có `targets` phải target nó, **và** `PHAM_VI` phải cho nó qua — dạng địa chỉ, không dạng type. Xem mục 4.

### 9.5 Verify

Viết `landing-zone/vi-du/kiem-vi-du.sh` đọc **AWS**. Truyền vào module:

```hcl
verify = "./landing-zone/vi-du/kiem-vi-du.sh '${var.deploy_role_arn}'"
```

Dấu nháy đơn quanh ARN là cố ý: một ARN rỗng giữa dãy tham số làm `$1` thành tham số kế tiếp, và script sẽ chạy với đối số sai mà không báo gì.

Role CodeBuild cần bốn quyền để `kiem-log.sh` đọc được log lần chạy vừa rồi — `codepipeline:ListPipelineExecutions`, `ListActionExecutions`, `logs:GetLogEvents`, `DescribeLogStreams`. Phép kiểm 14 đối chiếu: caller nào khai `verify` thì phải cấp đủ bốn.

### 9.6 Chạy bộ kiểm offline, rồi apply

```bash
cd landing-zone && python3 kiem-module.py          # 18 phép kiểm
python3 ops-gate/test-gate.py                      # 43 test
python3 trigger-filter/test-loc.py                 # 39 test

cd ops-pipeline-vi-du && terraform apply
cd ../vending-pipeline && ./push-tfvars.sh
git push codecommit HEAD:main
```

### 9.7 Lần chạy đầu phải là một lần KHÔNG CÓ THAY ĐỔI

Mọi stage phải ra `KHONG CO THAY DOI`. Để xem đường đi có thông không **trước khi** một thay đổi thật đi qua nó. Một pipeline mới chạy đúng một lần với một thay đổi thật thì chưa chứng minh được gì về lần thứ hai.

Sau đó mới bật `trigger-filter`, rồi mới đặt `tu_kich_hoat = false`. Đúng thứ tự đó.

---

## 10. `kiem-module.py` — 18 phép kiểm, và vì sao chúng tồn tại

Bộ kiểm này đối chiếu module với **mọi** caller, offline, không gọi AWS. Nó tồn tại vì hầu hết lỗi trong lớp này **không phát ra lỗi ở nơi có vấn đề**.

Vài phép kiểm đáng nhớ:

| # | Kiểm gì | Lỗi nó bắt |
|---|---|---|
| 10/11 | `ban_do` và `push-tfvars.sh` phủ hết layer | pipeline không bao giờ chạy; tfvars không có ở S3 |
| 13 | mọi `stage.value.X` có trong type của `var.stages` | Terraform âm thầm bỏ thuộc tính |
| 14 | caller có `verify` thì cấp đủ 4 quyền đọc log | Verify đỏ ở `ListPipelineExecutions` |
| 16 | `loosen` của layer nhiều stage đều có `stage` | khai báo stage A giết stage B |
| 17 | mọi biến `*_emails` có `validation` | `[""]` đi qua kiểu, nổ ở chỗ khác |
| 18 | stage có `targets` đều target chốt an toàn, **ở cả hai nơi** | 33 precondition vắng mặt trên đường tự động |

Một chốt chặn trong chính bộ kiểm: **0 caller không phải "mọi caller đều khớp"**.

```python
if not callers:
    print("  LOI  khong tim thay caller nao cua modules/tf-pipeline.")
    print("       Day KHONG phai 'khong co gi sai' - la CHUA TIM DUOC.")
```

---

## 11. Sổ quyết định

| Quyết định | Lý do |
|---|---|
| CodeCommit + CodePipeline, không GitHub Actions | GitHub không được tính là bề mặt điều khiển nội bộ |
| `gate.py` nằm ở `landing-zone/ops-gate/`, ngoài mọi pipeline | bảng LUẬT là chính sách an ninh; nhiều bản sao sẽ lệch, và bản lệch sẽ là bản **lỏng hơn** |
| Khoá stage mang tiền tố chủ sở hữu | `PHAM_VI` là một bảng dùng chung; hai stage trùng tên đè nhau |
| `FAIL_ON_DESTROY = yes` cứng, mọi stage | xoá không đi qua đường tự động, kể cả có khai nới lỏng |
| `precondition` thay vì `check` cho mâu thuẫn catalog | `check` chỉ cảnh báo; một rule trỏ tới app không tồn tại thì không có gì để "xem lại" |
| Verify đọc AWS, không đọc state/tfvars | `plan` ra `No changes` ở cả hai trạng thái đã-xác-nhận và chưa |
| Drift chỉ `plan`, không có nhánh apply | đoạn code apply **không tồn tại** — một biến có thể bị đè sai |
| `aws_sns_topic_policy` **không** có trong bảng `gate.py` | thêm nó là mở phạm vi cổng duyệt ra ngoài ba loại đã chốt; lý do ghi ở commit `d276cad` |
| Hai quy ước tên `qh11-lz` / `quh11-lz` cùng tồn tại | cả hai là tên thật từ `var.project` của hai layer; "sửa" cho khớp sẽ làm publish thất bại |
| `tfvars` dùng chung kho với `vending-pipeline` | hai kho là hai chỗ phải đẩy, và một kho cũ là một bản plan sai không có lỗi |

---

## 12. Việc còn lại

| Việc | Ghi chú |
|---|---|
| Dọn catalog test của `network/ops` | `endpoints.yaml` (KMS endpoint) trước — dòng duy nhất tốn tiền, ~$14.60/tháng. Phải làm **tay**: destroy không đi qua pipeline |
| Firewall `alert` → `drop` | ở `var.firewall_mode` layer cha, sau khi đọc đủ log UNMATCHED east-west. Tới lúc đó 7 rule đang nạp mà **không quyết định gì** |
| Đường báo drift chạy thật | khai báo đã thông cho cả 5 role; nhánh `publish` chỉ chạy khi **có** phát hiện, nên chưa ai đi thử |
| `tu_kich_hoat = false` cho ops-network | hiện `true`, nên mỗi commit vào main park một phiếu duyệt |
| `-no-color` trong `buildspec-terraform.yml` | và câu thông báo "KHONG co cong duyet" ở mục 3.2 — cùng một rào: phải apply lại `vending-pipeline` |
| Tag policy nhịp 2 (`enforced_for`) | sau báo cáo tuân thủ 48 giờ |
| Thu hẹp `OrganizationAccountAccessRole` | ba account đích hiện chỉ có role full admin này |

---

## Liên quan

- [Sơ đồ tổng quan — Luồng pipeline Landing Zone](https://claude.ai/code/artifact/efa04c8c-f8a3-4cae-9a97-250e75fdd1f9) — năm hình vẽ tương ứng với mục 2, 3, 2.2, 5 và 7
- [Doc 10 — CI/CD bằng GitHub Actions + OIDC](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) — thiết kế bị chính sách loại, còn giữ để so sánh
- [Doc 20 — Remote state và quy trình thay đổi](./20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md) — kiến trúc state mà pipeline dùng
- [Doc 22 — Nhật ký triển khai LZ DIY](./22-Nhat-ky-Trien-khai-LZ-DIY.md) — từng lỗi, theo thứ tự gặp
- [Doc 25 — Vận hành network hằng ngày](./25-Van-hanh-Network-Hang-Ngay.md) — catalog mà `ops-network` apply
- [Doc 27 — Vận hành account vending](./27-Van-hanh-Account-Vending.md)
- [`landing-zone/RUNBOOK.md`](../landing-zone/RUNBOOK.md) — trình tự dựng LZ, giai đoạn 0 trở đi
