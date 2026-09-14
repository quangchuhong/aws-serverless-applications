# Pipeline vận hành LZ — CodeCommit, CodePipeline, và sáu lớp kiểm

[Doc 10](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) là thiết kế CI/CD bằng GitHub Actions + OIDC. Tài liệu này là thứ **đã dựng thật**, và nó không phải doc 10: chính sách công ty không cho GitHub làm bề mặt điều khiển, nên toàn bộ đường tự động nằm trong AWS — CodeCommit, CodePipeline, CodeBuild. Repo GitHub vẫn tồn tại như một bản sao để đọc và review, nhưng **nó không kích hoạt gì cả**.

Code: [`modules/tf-pipeline/`](../modules/tf-pipeline/) (module dùng chung), [`landing-zone/ops-pipeline*/`](../landing-zone/) (năm caller), [`landing-zone/ops-gate/`](../landing-zone/ops-gate/) (cổng chặn).

> **Sơ đồ tổng quan:** [Luồng pipeline Landing Zone](https://claude.ai/code/artifact/efa04c8c-f8a3-4cae-9a97-250e75fdd1f9) — năm hình vẽ: đường kích hoạt, khung một pipeline với sáu lớp kiểm đặt đúng chỗ chúng chạy, phân bổ năm pipeline sang bốn account, vòng bốn nhịp nới lỏng, và đường drift. Đọc hình trước nếu bạn mới vào; các mục dưới đây là phần chi tiết của chính năm hình đó.

**Đọc mục 1 trước mọi mục khác.** Nó trả lời *vì sao* luồng có hình dạng này — chín quyết định, ba ràng buộc sinh ra chúng, và cái giá của từng cái. Không hiểu phần đó thì mọi bước còn lại đọc như thủ tục hành chính, và thủ tục nào không hiểu lý do thì sớm muộn cũng bị đi đường tắt.

---

## 0. Trạng thái

| | |
|---|---|
| **Pipeline** | **5 pipeline, 8 stage, đã chạy thật** — mọi pipeline đã đi hết vòng Nguồn → Lint → Plan → Apply → Verify |
| **Module** | `modules/tf-pipeline` — 30 biến, 10 output, 4 buildspec template |
| **Cổng chặn** | `gate.py` — 37 loại resource có luật chiều NỚI/THẮT, 8 stage trong bảng phạm vi |
| **Verify** | 5 script đọc **AWS**, không đọc state; dùng chung `kiem-log.sh` |
| **Bộ kiểm offline** | `kiem-module.py` 18 phép kiểm · `test-gate.py` 43 test · `test-loc.py` 39 test |
| **Đã chứng minh** | Đường drift → SNS → email **chạy thật** — thư tới hộp `alert_emails` của `config-detective` |
| **Chưa** | Job drift **không kiểm được `network/ops`** (thiếu assume role — mục 7.11) · firewall còn `alert` · `tu_kich_hoat = true` ở ops-network |

Các lỗi gặp khi dựng lớp này ghi ở [doc 22](./22-Nhat-ky-Trien-khai-LZ-DIY.md). Mục 8.4 dưới đây tóm bảy cái đắt nhất, vì chúng nói về **cách đọc** chứ không chỉ về một dòng code.

---

## 1. Vì sao luồng có hình dạng này

Phần này trả lời câu hỏi mà một người mới vào sẽ hỏi trước mọi câu khác: *tại sao lại phải qua nhiều bước như vậy để sửa một dòng YAML?*

Mỗi lựa chọn dưới đây đều kèm **cái giá** của nó. Một mục "vì sao" chỉ kể lợi ích là quảng cáo, không phải tài liệu — và cái giá là thứ người vận hành gặp hằng ngày, còn lợi ích thì chỉ thấy vào ngày có sự cố.

### 1.1 Ba ràng buộc sinh ra mọi thứ còn lại

Không có quyết định nào dưới đây là sở thích. Cả chín cái đều suy ra từ ba ràng buộc:

| | Ràng buộc | Nó buộc ra cái gì |
|---|---|---|
| **A** | GitHub không được tính là bề mặt điều khiển nội bộ | Không có PR → chỗ review phải dịch vào **trong** pipeline (1.2, 1.7) |
| **B** | Một layer = một state, nhưng chứa những thứ đổi với **nhịp rất khác nhau** | `-target` + nhiều stage trong một pipeline (1.5, 1.6) |
| **C** | Không ai mở log của một job chạy lúc 2 giờ sáng | Mọi phát hiện phải **làm cái gì đó đỏ**, chứ không chỉ ghi ra (1.8, 1.9) |

Ràng buộc C là cái ít hiển nhiên nhất và lại quyết định nhiều nhất. Nó là lý do job drift `exit 1` khi phát hiện drift, lý do `--strict` biến cảnh báo thành lỗi, và lý do một khai báo nới lỏng bị quên xoá sẽ làm pipeline đỏ. Một hệ thống chỉ *ghi lại* vấn đề là một hệ thống không có vấn đề nào được sửa.

### 1.2 Vì sao không phải GitHub Actions

Doc 10 vẫn là một thiết kế đúng, và nếu chính sách khác thì nó là lựa chọn tốt hơn: ít hạ tầng hơn, review và pipeline cùng một chỗ. Nó bị loại vì ràng buộc A. Hệ quả kỹ thuật thì có thật và phải ghi ra, vì chúng đổi cách vận hành:

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

### 1.3 Vì sao `plan` và `apply` là HAI stage, không phải một lệnh

Đây là quyết định có hệ quả lớn nhất, và nó không phải để "cẩn thận hơn".

Stage `apply` **không plan lại**. Nó chạy đúng file `tfplan` mà stage plan đã lưu và truyền qua như artifact — thiếu file đó là lỗi cứng:

```sh
if [ ! -f tfplan ]; then
  echo "LOI: khong thay file tfplan."
  echo "     Stage apply phai nhan artifact tu stage plan cua CHINH no."
  exit 1
fi
```

Nếu apply tự plan lại thì mọi lớp kiểm ở giữa trở thành vô nghĩa: `gate.py` đã đọc một bản plan, con người đã duyệt một bản plan, rồi AWS thi hành **một bản plan khác** — bản mới, sinh ra sau đó, có thể khác vì hạ tầng vừa đổi hoặc vì ai đó vừa đẩy commit. Người duyệt sẽ đã duyệt một thứ không xảy ra.

**Giá phải trả:** một bản plan cũ có thể không apply được nữa (state đã đổi), và khi đó pipeline đỏ ở apply thay vì tự chữa. Đó là đánh đổi có chủ đích — thà chạy lại từ plan còn hơn thi hành một thứ chưa ai đọc.

### 1.4 Vì sao một pipeline cho mỗi CHỦ SỞ HỮU, không phải một pipeline cho cả LZ

Một pipeline duy nhất apply mọi layer sẽ có ba vấn đề, và cái thứ ba là cái thật sự giết:

1. Một layer hỏng chặn mọi layer khác.
2. Bán kính một lần chạy sai bằng cả Landing Zone.
3. **Một nút re-run, một luồng thông báo, một người nhận.** Sec và cloudops sẽ nhận cảnh báo của nhau, và chuyện đó kết thúc bằng việc cả hai bên thôi đọc.

Nên tách theo chủ sở hữu: sec giữ guardrail ở `organization`, cloudops vận hành phần còn lại. Hai role, hai luồng thông báo, hai nút re-run.

**Giá phải trả:** năm caller gần giống nhau, tức năm chỗ có thể lệch nhau. Đó chính là lý do `modules/tf-pipeline` tồn tại, và lý do `kiem-module.py` đối chiếu **mọi** caller với module thay vì kiểm từng cái.

### 1.5 Vì sao nhiều stage trong MỘT pipeline, không phải nhiều pipeline

`organization` có ba stage (`sec-ou`, `sec-scp`, `sec-tagging`) dùng **cùng một layer và cùng một state**. Không tách thành ba layer, vì tách state là thêm hai lần init, hai khoá, và hai chỗ để lệch.

Nhưng chúng cũng không thể là ba pipeline, vì **thứ tự có ý nghĩa**: đổi tên một OU làm khoá của `aws_organizations_policy_attachment.scp` đổi theo (khoá là `<policy>|<tên OU>`), nên Terraform thấy destroy + create trên cùng một OU id. Nếu SCP chạy trước OU ở một pipeline khác, OU đổi xong rồi không có gì đối chiếu lại attachment cho tới lượt sau — và state với cấu hình lệch nhau trong im lặng suốt khoảng giữa.

Một pipeline, nhiều stage, chạy theo thứ tự khai trong `local.stages`. Chặn vẫn xảy ra, nhưng chặn **trong cùng một lượt chạy**.

**Giá phải trả:** một stage đỏ chặn các stage sau nó trong cùng layer.

### 1.6 Vì sao `-target`, khi tài liệu Terraform nói đừng dùng

Terraform nói `-target` chỉ dành cho tình huống ngoại lệ. Ở đây nó là thiết kế, vì ràng buộc B: một layer chứa những thứ đổi **hằng ngày** cạnh những thứ đổi **vài lần một năm**.

`config-detective` là ví dụ rõ nhất. Cùng một layer, cùng một state, quản: Config rule (đổi hằng tuần), và recorder, aggregator, Security Hub, GuardDuty, bucket log, đường báo động (đổi vài lần một năm). Stage `cloudops-config-rules` `-target` vào **đúng một** resource:

> *Một pipeline tự apply được chúng là một pipeline có thể **tắt cả hệ thống phát hiện** của tổ chức trong một lần chạy.*

`-target` là cách cho hai nhịp khác nhau đi qua cùng một state mà không phải tách state.

**Giá phải trả, và nó đắt:**

- `-target` giới hạn **apply**, nhưng `plan` vẫn refresh **toàn bộ** state → role cần **đọc rộng, ghi hẹp**, và một quyền đọc bị thiếu làm cả plan chết với thông báo không nhắc gì tới `-target`.
- Output bị loại khỏi plan → phải `apply -refresh-only` sau đó, nếu không state có resource mới mà output cũ.
- Resource **không** nằm trong target thì `precondition` của nó **không được tính** → 33 chốt cứng từng vắng mặt suốt nhiều lần chạy (mục 3.3).
- Những gì không ai target thì không ai apply, và job drift sẽ báo lệch vĩnh viễn.

Ba trong bốn cái giá đó đã sập thật. Đó là lý do mục 4 và phép kiểm 18 tồn tại.

### 1.7 Vì sao cổng duyệt nằm GIỮA plan và apply

Nếu có PR thì review sẽ ở PR. Không có PR (ràng buộc A), nên duyệt phải dịch vào trong pipeline. Nhưng chỗ đặt nó không chỉ là "chỗ còn lại" — nó là **chỗ tốt hơn**:

Một review code trả lời *"đoạn code này có đúng không"*. Một review **bản plan** trả lời *"AWS sắp làm gì"*. Hai câu đó khác nhau, và câu thứ hai là câu người duyệt cần. Một thay đổi catalog một dòng có thể sinh ra một plan mở một cửa vào production — chỉ bản plan nói ra điều đó.

Và nó chỉ bật ở stage nào cần: `approve_stages` hiện chỉ có `cloudops-firewall`. Stage `cloudops-network` không có cổng duyệt, vì một thay đổi DNS sai **có triệu chứng ngay**; một ingress rule mới thì không có gì cả.

**Giá phải trả:** một lần chạy đợi người sẽ treo tới khi hết giờ — **7 ngày** — và một pipeline treo đọc giống một pipeline hỏng. Nặng hơn: `tu_kich_hoat = true` nghĩa là mọi commit vào `main` park một phiếu duyệt, kể cả commit không liên quan.

### 1.8 Vì sao verify là stage RIÊNG, sau apply

Ba lý do, và lý do thứ ba là cái quyết định:

1. Nó chạy **dù apply không đổi gì**. Một lần chạy "0 added, 0 changed" vẫn phải chứng minh thực tế đúng như ta tưởng.
2. Nó đọc **AWS**, không đọc state. `terraform plan` ra `No changes` ở cả hai trạng thái "email đã bấm xác nhận" và "chưa bấm" — state không trả lời được câu hỏi đó.
3. Nó **không được đưa** Terraform, state, hay tfvars. `buildspec-verify.yml` không cài Terraform và không kéo tfvars. Một script verify đọc tfvars sẽ so khai báo với khai báo — tức trả lời một câu hỏi khác câu nó tưởng đang trả lời.

> **Nói cho chính xác:** đây **không** phải ranh giới quyền. Project verify dùng **cùng** IAM role với project terraform (`aws_iam_role.codebuild[0]`). Ranh giới là *thứ nó được đưa*, không phải *thứ nó được phép* — một script verify hoàn toàn có thể gọi API ghi nếu ai đó viết vậy. Muốn thành ranh giới thật thì cần một role riêng chỉ-đọc; chưa làm.

**Giá phải trả:** verify có thể đỏ vì một cảnh báo không phải do lần chạy này gây ra, và nó không phân biệt được "tôi vừa làm hỏng" với "chuyện này hỏng từ tuần trước".

### 1.9 Vì sao drift là job theo lịch, không phải một stage

Một stage chỉ chạy khi có người push. Mục đích của drift là bắt đúng những gì xảy ra **khi không ai push** — ai đó sửa tay trong console, một lần apply trước chưa hoàn tất. Đặt nó thành một stage là đặt nó ở chỗ nó không bao giờ thấy được thứ nó đi tìm.

Và nó **chỉ** `plan`. Không có nhánh apply — không phải vì một biến được đặt đúng, mà vì **đoạn code apply không tồn tại**. Một biến có thể bị đè sai; một đoạn code không có thì không.

**Giá phải trả:** drift phát hiện nhưng không sửa, nên nó tạo ra việc cho người. Và nó `plan` không `-target`, nên mọi thứ pipeline không chạm tới được sẽ hiện ra như drift vĩnh viễn — một cảnh báo luôn kêu, tức ràng buộc C bị phá từ bên trong. Đó là vì sao mục 4 phải được sửa cho đúng.

### 1.10 Vì sao catalog YAML và một lớp lint offline

Việc vận hành hằng ngày — mở một port, thêm một endpoint, cho một tên vào DNS — là **sửa dữ liệu**, không phải sửa code. Catalog YAML làm được hai thứ:

- Một lỗi schema chết ở stage `Lint`, **trước khi** có gì gọi tới AWS. Nhanh, offline, không tốn một lần assume role nào.
- Diff của một thay đổi đọc được bởi người không viết Terraform.

**Giá phải trả:** hai lớp biểu diễn (YAML → HCL) nghĩa là số mục trong catalog **không** bằng số dòng luật ở AWS — một mục `firewall-rules.yaml` có thể thành một dòng Suricata phủ nhiều port. Verify cố ý **không** so hai số đó, và nói ra là nó không so (mục 6).

### 1.11 Tóm lại: chín quyết định, chín cái giá

| Quyết định | Nó mua được gì | Giá |
|---|---|---|
| CodeCommit thay GitHub Actions | tuân chính sách | mất PR, mất chỗ review tự nhiên |
| plan và apply là hai stage | duyệt cái gì thì thi hành đúng cái đó | plan cũ có thể không apply được |
| một pipeline / chủ sở hữu | bán kính nhỏ, thông báo đúng người | năm caller có thể lệch nhau |
| nhiều stage / một pipeline | thứ tự đúng, một state | một stage đỏ chặn stage sau |
| `-target` | hai nhịp thay đổi, một state | đọc rộng-ghi hẹp, mất output, mất precondition |
| duyệt giữa plan và apply | người đọc **bản plan**, không đọc code | treo 7 ngày; mọi commit park một phiếu |
| verify là stage riêng | đọc AWS, chạy cả khi 0 thay đổi | không phải ranh giới quyền; không phân biệt lỗi mới/cũ |
| drift theo lịch | thấy được cái xảy ra khi không ai push | tạo việc cho người; dễ thành cảnh báo luôn kêu |
| catalog YAML + lint | chết sớm, offline, diff đọc được | hai lớp biểu diễn, hai con số không bằng nhau |

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

> Chi tiết đầy đủ — năm phép kiểm cấu trúc, các nhánh fail-open, và vì sao Lambda phải `raise` — ở [doc 29 phần I](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md#phần-i--trigger-filter).

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

### 2.4 Năm layer, cụ thể từng cái

Bảng ở 2.2 nói pipeline nào apply layer nào. Mục này nói **trong mỗi layer có gì**, pipeline sửa được phần nào, và phần nào phải sửa tay.

Mỗi layer viết theo cùng một hình dạng, và dòng quan trọng nhất là **"phải sửa tay"**. Đó không phải giới hạn kỹ thuật — nó là câu trả lời cho *"nếu tôi sửa dòng này rồi push thì có gì xảy ra không"*. Câu trả lời thường là **không có gì**, và đó là kiểu hỏng không có triệu chứng.

#### `landing-zone/organization` — SCP, cây OU, tag policy

| | |
|---|---|
| **Nó chứa gì** | Guardrail của cả tổ chức: các SCP, cây OU hai tầng, tag policy, và đăng ký delegated administrator |
| **Ai sửa** | `qh11-lz-ops` — **sec** sở hữu. Ba stage, một layer, một state |
| **Pipeline sửa được** | `sec-ou` → cây OU · `sec-scp` → SCP và chỗ gắn SCP · `sec-tagging` → tag policy và chỗ gắn |
| **Phải sửa tay** | `aws_organizations_organization` (chính cái tổ chức) và `aws_organizations_delegated_administrator` |
| **Đổi bao lâu một lần** | SCP: vài lần một tháng · cây OU: vài lần một năm |
| **Verify đọc** | `kiem-to-chuc.sh` — SCP **đang gắn thật** ở AWS và cây OU thật |
| Khoá state · account | `organization/terraform.tfstate` · **management** (Organizations API chỉ gọi được từ đó) |
| Chốt cứng | `terraform_data.scp_guard` — 2 precondition |

**Ví dụ một yêu cầu thật:** *"Chặn mọi account khỏi tắt CloudTrail."* → thêm một statement Deny vào định nghĩa SCP → stage `sec-scp`. `gate.py` thấy đây là **thắt**, nên đi qua không cần phiếu.

Ngược lại: *"Cho security account làm delegated admin của GuardDuty."* → `aws_organizations_delegated_administrator` → **sửa tay**, pipeline không chạm tới.

**Điều riêng của layer này:** thứ tự ba stage có ý nghĩa. Đổi tên một OU làm khoá của chỗ gắn SCP đổi theo (khoá là `<policy>|<tên OU>`), nên Terraform thấy destroy + create. Nếu SCP chạy trước OU, chỗ gắn không được đối chiếu lại cho tới lượt sau. Đó là vì sao ba stage ở **cùng một pipeline** (mục 1.5).

#### `landing-zone/org-trail` — CloudTrail cấp tổ chức

| | |
|---|---|
| **Nó chứa gì** | Một trail ghi mọi API call của mọi account, và cái bucket chứa log đó — kèm 7 resource cấu hình bucket |
| **Ai sửa** | `qh11-lz-ops-trail` — cloudops. Một stage |
| **Pipeline sửa được** | `aws_cloudtrail.this` — **đúng một resource** |
| **Phải sửa tay** | Toàn bộ bucket log: policy, versioning, mã hoá, public access block, ownership, lifecycle, và **object lock** |
| **Đổi bao lâu một lần** | Gần như không đổi |
| **Verify đọc** | `kiem-trail.sh` — trail, log file validation, bucket |
| Khoá state · account | `org-trail/terraform.tfstate` · trail ở **management**, bucket ở **log-archive** |

**Ví dụ một yêu cầu thật:** *"Ghi thêm data event của S3 vào trail."* → `aws_cloudtrail.this` → pipeline làm được.

Ngược lại: *"Giữ log 10 năm thay vì 7."* → lifecycle của bucket → **sửa tay**.

**Vì sao bucket nằm ngoài tầm pipeline:** object lock. Một bucket log có object lock mà một đường tự động sửa được thì object lock không còn nghĩa gì — thứ nó bảo vệ chính là việc **không ai** xoá được log, kể cả người có quyền.

#### `landing-zone/permission-sets` — ai vào account nào

| | |
|---|---|
| **Nó chứa gì** | Hai thứ khác nhau: **các permission set** (một set = một bộ quyền), và **các assignment** (group nào dùng set nào ở account nào) |
| **Ai sửa** | `qh11-lz-ops-permission-set` — cloudops. Một stage |
| **Pipeline sửa được** | assignment và thành viên group — tức **ai vào account nào** |
| **Phải sửa tay** | Bản thân permission set: inline policy, managed policy gắn kèm, và user trong Identity Store |
| **Đổi bao lâu một lần** | assignment: hằng tuần · nội dung permission set: vài lần một năm |
| **Verify đọc** | `kiem-quyen.sh` — assignment thật theo từng account |
| Khoá state · account | `permission-sets/terraform.tfstate` · **management** (IAM Identity Center) |
| Đọc state layer khác | `account-baseline/terraform.tfstate` — lấy danh sách account vừa vend |

**Ví dụ một yêu cầu thật:** *"Nhóm dev cần vào account nonprod vừa tạo."* → một assignment mới → pipeline làm được. `gate.py` coi **tạo** một assignment là **nới** (một group vừa vào được một account mới), nên phải khai `loosen` kèm ticket.

Ngược lại: *"Nhóm dev cần thêm quyền RDS."* → sửa inline policy của permission set → **sửa tay**.

**Vì sao ranh giới nằm đúng ở đó:** tạo một assignment là cho *một* group vào *một* account. Đổi nội dung một permission set là đổi quyền của **mọi** người đang dùng set đó, ở **mọi** account, **ngay lập tức** — không ai phải đăng nhập lại. Việc thứ hai không phải việc hằng ngày, nên nó không nằm trên đường hằng ngày.

Đây cũng là layer đầu tiên có `state_chi_doc`. Thiếu dòng đó thì plan chết với `403 Forbidden` trên S3, và thông báo không nhắc gì tới `terraform_remote_state`.

#### `landing-zone/config-detective` — Config rule, và cả lớp phát hiện

| | |
|---|---|
| **Nó chứa gì** | Lớp phát hiện của cả tổ chức: Config rule, recorder rải xuống mọi account, aggregator, Security Hub, GuardDuty, bucket snapshot, và **đường báo động** (SNS + EventBridge) |
| **Ai sửa** | `qh11-lz-ops-config-rules` — cloudops. Một stage |
| **Pipeline sửa được** | `aws_config_organization_managed_rule.this` — **đúng một resource trên 75** |
| **Phải sửa tay** | Tất cả phần còn lại: recorder StackSet, aggregator, Security Hub, GuardDuty, bucket, SNS topic + policy + subscription, EventBridge rule |
| **Đổi bao lâu một lần** | rule: hằng tuần · phần còn lại: vài lần một năm |
| **Verify đọc** | `kiem-config.sh` — org config rule, qua **đúng cửa mà apply dùng** (assume vào security) |
| Khoá state · account | `config-detective/terraform.tfstate` · **security** + **log-archive** + StackSet xuống mọi account thành viên |

**Ví dụ một yêu cầu thật:** *"Bật thêm rule kiểm EBS đã mã hoá chưa."* → thêm một dòng vào `organization_rules` → pipeline làm được.

Ngược lại: *"Thêm một địa chỉ nhận cảnh báo bảo mật."* → `alert_emails` → **sửa tay**. Và *"cho role CodeBuild của ops-network gửi được vào topic này"* → `aws_sns_topic_policy.alerts` → cũng **sửa tay**:

```bash
cd landing-zone/config-detective && terraform apply -target=aws_sns_topic_policy.alerts
```

**Vì sao tỷ lệ 1/75:** chú thích ở đầu caller nói thẳng — *một pipeline tự apply được chúng là một pipeline có thể **tắt cả hệ thống phát hiện** của tổ chức trong một lần chạy.*

#### `landing-zone/network/ops` — lớp vận hành mạng

| | |
|---|---|
| **Nó chứa gì** | Bề mặt vận hành mạng hằng ngày: DNS nội bộ, VPC endpoint, route ngoại lệ, dịch vụ công bố cho đối tác, luật tường lửa east-west, alarm VPN |
| **Ai sửa** | `qh11-lz-ops-network` — cloudops. **Hai** stage |
| **Pipeline sửa được** | `cloudops-network` → 13 resource (DNS, endpoint, route, NLB, alarm) · `cloudops-firewall` → nhóm luật tường lửa và ingress rule, **có cổng duyệt** |
| **Phải sửa tay** | **Không có gì** — cả **16** resource của layer đều nằm trong target của một trong hai stage |
| **Đổi bao lâu một lần** | **Hằng ngày** |
| **Verify đọc** | `kiem-mang.sh` — nhóm luật, hành động mặc định của policy, alarm, subscription |
| Khoá state · account | `demo-network-lz-full/ops/terraform.tfstate` — **khoá không khớp đường dẫn, có chủ đích** · **network**, qua assume role |
| Đọc state layer khác | `demo-network-lz-full/terraform.tfstate` — layer cha: TGW, VPC, vùng |
| Chốt cứng | `terraform_data.catalog_guard` — **31** precondition |

**Ví dụ một yêu cầu thật:** *"Đội A xin mở port 443 sang đội B ở VPC khác."* → thêm một khối vào `firewall-rules.yaml` → stage `cloudops-firewall` → `gate.py` thấy **nới** → khai `loosen` kèm ticket → **một người duyệt** → apply.

Đây là layer duy nhất có **catalog YAML** (`apps`, `firewall-rules`, `routes`, `endpoints`, `dns-records`, `partners`) và duy nhất có **cổng duyệt**.

**Vì sao pipeline được chạm toàn bộ:** đó là nhất quán, không phải lỏng tay — cả layer này *chính là* bề mặt vận hành. Nó không chứa hạ tầng nền; hạ tầng nền ở layer cha.

**Khoá state không khớp đường dẫn là chủ đích.** Layer này trước ở `demo/network-lz-full` và đã apply thật; khi đường dẫn đổi, khoá state giữ nguyên. Đổi khoá nghĩa là Terraform mở một state **rỗng**: plan đòi tạo lại ~200 resource, và hạ tầng thật thành mồ côi — vẫn chạy, vẫn tính tiền, không còn ai quản.

#### Layer cha `landing-zone/network` — không pipeline vận hành nào chạm

| | |
|---|---|
| **Nó chứa gì** | Hạ tầng nền, ~**200** resource: TGW, 17 subnet, 17 route table, security VPC, Network Firewall policy, VPN đối tác |
| **Ai sửa** | `vending-pipeline` — **không** phải một trong năm pipeline vận hành |
| Khoá state | `demo-network-lz-full/terraform.tfstate` |

`network/ops` **đọc** state này. Nên hai thứ lớp vận hành phụ thuộc vào mà **không sửa được**:

- `var.firewall_mode` — `alert` hay `drop`. Lớp ops nạp luật; layer cha quyết định luật có chặn gì không.
- SNS topic `netops` và các alarm action đi kèm.

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

> Chi tiết đầy đủ — sáu phép so sánh, bốn luật ngầm chạy trước chúng, và bốn cái bẫy của `kiem-log.sh` — ở [doc 29 phần II](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md#phần-ii--ops-gate).

**Hai chữ phải hiểu trước: NỚI và THẮT.** Chúng nói về **quyền**, không liên quan gì tới mới/cũ (`nới` rất dễ đọc nhầm thành `mới`).

| | Nghĩa | Ví dụ |
|---|---|---|
| **nới** | sau thay đổi, có thứ **được phép hơn** trước | xoá một SCP Deny · thêm account vào `excluded_accounts` · tạo một ingress rule |
| **thắt** | sau thay đổi, có thứ **bị chặn hơn** trước | thêm một SCP Deny · xoá một ingress rule · bật lại một Config rule |

**`gate.py` chỉ chặn chiều *nới*.** Chiều *thắt* đi qua tự do — bạn không bao giờ phải xin phép để làm hệ thống an toàn hơn.

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

## 7. Drift — chạy như thế nào

### 7.1 Nó không phải một stage

Drift **không nằm trong** pipeline. Nó là một CodeBuild project riêng với một EventBridge rule riêng theo lịch. Mỗi pipeline có một cái:

```
qh11-lz-ops-network          pipeline  — chạy khi có người push
qh11-lz-ops-network-drift    job riêng — chạy theo đồng hồ
```

Lịch mặc định `cron(0 19 * * ? *)` là giờ **UTC**, tức **2 giờ sáng giờ Việt Nam**. Nên câu "không ai mở log của một job chạy lúc 2 giờ sáng" ở mục 1.1 là nghĩa đen, không phải cách nói.

### 7.2 Nó chạy trên những layer nào

Một biến môi trường `LAYERS` mang danh sách `<đường dẫn layer>=<khoá state>`, cách nhau bằng dấu cách:

```hcl
LAYERS = join(" ", [for l, k in local.stage_keys : "${l}=${k}"])
```

`stage_keys` là các layer **khác nhau** của pipeline đó. Với `ops-network` nó ra đúng một mục, dù pipeline có hai stage — vì hai stage ấy cùng một layer:

```
landing-zone/network/ops=demo-network-lz-full/ops/terraform.tfstate
```

Hôm nay **cả năm pipeline đều đúng một layer**. Vòng lặp tồn tại cho trường hợp một pipeline apply nhiều layer, chưa phải hiện tại.

### 7.3 Với mỗi layer, nó làm gì

Sáu bước, giống hệt stage Plan — trừ ba chỗ, và ba chỗ đó là toàn bộ sự khác biệt:

| | Stage Plan | Job drift |
|---|---|---|
| kéo tfvars từ S3 | có | có |
| sinh `backend.tf`, `init` theo khoá state | có | có |
| kiểm state rỗng | có | có |
| **`-target`** | **có** | **KHÔNG** |
| khoá state khi plan | có | **`-lock=false`** |
| nhánh apply | có | **không tồn tại trong file** |

`-lock=false` là cố ý: bước này chạy theo lịch và có thể trùng với một lần apply thật. Một phép **kiểm** làm chặn một lần **sửa** là một phép kiểm gây ra sự cố.

Không có nhánh apply — không phải vì một biến được đặt đúng, mà vì **đoạn code apply không tồn tại**. Một biến có thể bị đè sai; một đoạn code không có thì không.

### 7.4 Làm sao nó biết có drift: `-detailed-exitcode`

Đây là mấu chốt của cả cơ chế.

`terraform plan` bình thường **luôn thoát 0** — dù có thay đổi hay không. Nên một script không đọc được kết quả. Cờ `-detailed-exitcode` đổi điều đó:

| Mã thoát | Nghĩa |
|---|---|
| `0` | không có thay đổi nào |
| `2` | **có** thay đổi |
| khác | plan hỏng |

Chính cờ đó biến `plan` từ một bản **báo cáo** thành một phép **thử**:

```sh
terraform plan -input=false -lock=false -detailed-exitcode -no-color > /tmp/plan.txt
CODE=$?
case "$CODE" in
  0) echo "   KHONG CO THAY DOI" ;;
  2) tail -60 /tmp/plan.txt; SO_DRIFT=$((SO_DRIFT + 1)) ;;
  *) tail -40 /tmp/plan.txt; SO_HONG=$((SO_HONG + 1)) ;;
esac
```

Hai chốt **trước** khi tới plan cũng cộng vào `SO_HONG`, và cả hai đều `continue` chứ không chạy tiếp:

| Chốt | Vì sao không chạy plan tiếp |
|---|---|
| không kéo được tfvars từ S3 | mọi biến đều có mặc định, nên plan sẽ **thành công** và mô tả một tổ chức không có gì — tức báo drift giả ở mức tối đa |
| `terraform state list` ra 0 resource | state rỗng nghĩa là **sai khoá**, không phải drift |

### 7.5 Ba kết cục

```sh
if [ "$SO_DRIFT" = "0" ] && [ "$SO_HONG" = "0" ]; then
  echo "Moi layer khop state."
  exit 0                      # ← xanh, và KHÔNG gửi gì
fi
# ... soạn thư vào một file ...
aws sns publish ...           # ← chỉ tới đây khi CÓ phát hiện
exit 1                        # ← build ĐỎ
```

Job thoát khác 0 khi có phát hiện, để lần chạy hiện ra là **thất bại** trong console và mọi bảng theo dõi. Một job xanh mang tin xấu bên trong là một job không ai mở ra.

### 7.6 Vì sao `SO_HONG` đếm riêng

"Không kiểm được" **không phải** "sạch".

Một layer thiếu tfvars hay sai khoá state không sinh ra dòng drift nào. Nếu chỉ đếm `SO_DRIFT` thì báo cáo nói **"0 drift"** cho một hệ thống **chưa hề được nhìn** — và đó là câu trả lời sai nguy hiểm hơn cả một câu trả lời sai, vì nó trấn an.

### 7.7 Vì sao không `-target` — và hệ quả

Đây là khác biệt quan trọng nhất so với pipeline.

Pipeline chỉ nhìn những resource trong `targets`. Drift nhìn **cả layer**. Nên nó thấy đúng những gì không ai apply — tức những thứ dễ trôi nhất, và những thứ không lớp nào khác nhìn tới.

Hệ quả ngược cũng thật: bất cứ thứ gì pipeline **không chạm tới được** sẽ hiện ra như drift **mỗi đêm, vĩnh viễn**. Đó chính là chuyện đã xảy ra với `terraform_data.catalog_guard` trước khi nó được đưa vào `targets` (mục 4). Một cảnh báo luôn kêu thì chẳng mấy sẽ không ai đọc — tức ràng buộc C ở mục 1.1 bị phá từ bên trong.

### 7.8 Chạy tay

```bash
aws codebuild start-build --project-name qh11-lz-ops-network-drift --region ap-southeast-1
```

`terraform output drift_project` in sẵn lệnh này ở trường `chay_tay`.

**Nhưng trên một hệ thống sạch, lần chạy đó không kiểm được gì về đường báo động**: job thoát 0 ở 7.5 *trước* khối `sns publish`. Xem 7.10.

### 7.9 Khai đích báo về đâu

| | |
|---|---|
| `drift_emails = ["…"]` | layer tự tạo topic ở **chính account này** — không phụ thuộc liên account |
| `drift_topic_arn = "…"` | dùng một topic **có sẵn** |

**Chọn một.** Khai cả hai thì `drift_topic_arn` thắng, topic tự tạo **không** được tạo, và những địa chỉ trong `drift_emails` nhận số không. `check "khong_khai_ca_hai_nguon_topic"` có cảnh báo — nhưng `check` không bao giờ làm apply dừng.

Và `[""]` **không phải** `[]`: nó là danh sách có một phần tử rỗng, `length()` trả về 1. Tuỳ cấu hình mà nó im lặng hôm nay và nổ hôm sau. Nay 17 biến `*_emails` có `validation` chặn ở plan, và `kiem-module.py` phép kiểm 17 giữ chỗ đó.

Nếu topic nằm ở **account khác**: SNS liên account đòi **cả hai** phía cho phép. Quyền IAM của bên gửi là chưa đủ — resource policy của topic cũng phải cho:

```bash
aws sns get-topic-attributes --topic-arn <arn> --query 'Attributes.Policy' --output text \
  | python3 -m json.tool     # tìm AllowCrossAccountPublish
```

Topic của `config-detective` nằm ngoài tầm pipeline (mục 2.4), nên thêm publisher là apply **tay**:

```bash
cd landing-zone/config-detective && terraform apply -target=aws_sns_topic_policy.alerts
```

### 7.10 Nhánh chưa ai đi thử

Khi publish thất bại, nó thất bại **im lặng**:

```sh
if aws sns publish ...; then echo "Da bao ve ..."
else echo "CANH BAO: khong bao duoc ve SNS - xem quyen sns:Publish"; fi
```

`else` không làm build đỏ. Ghép với 7.5 — nhánh publish chỉ chạy khi *có* phát hiện — nên trên một hệ thống sạch, nhánh này **không thể** được đi thử.

**Đã chứng minh là thông.** Một lần chạy tay `qh11-lz-ops-network-drift` gặp `plan hong` (mục 7.11) → `SO_HONG = 1` → publish → thư tới. Cách nhận biết thư đến thật chứ không phải đọc log: dòng đầu

```
Buoc phat hien drift cua ops-pipeline vua chay.
```

chỉ tồn tại trong `$THU` — thân email — **không** có trong log CodeBuild. Kết quả này đúng cho **cả năm pipeline**, vì cùng một topic và cùng một resource policy.

Thư vào hộp `alert_emails` của `config-detective`, **không** phải địa chỉ trong `drift_emails` — cùng hộp với finding của Security Hub, phân biệt bằng tiêu đề `[LZ] drift: N layer doi, M khong kiem duoc`.

### 7.11 Job drift KHÔNG kiểm được `network/ops` — và nó đã báo đúng như vậy

Project drift có 7 biến môi trường: `TF_VERSION`, `STATE_BUCKET`, `STATE_REGION`, `STATE_LOCK_TABLE`, `TFVARS_BUCKET`, `DRIFT_TOPIC_ARN`, `LAYERS`.

**Không có `ASSUME_ROLE_ARN`**, và `buildspec-drift.yml` không nhắc chữ `assume` một lần nào. Stage Plan có `export TF_VAR_assume_role_arn` (mục 2.3 bước 3); job drift thì không.

`ops-pipeline-network` là caller **duy nhất** khai `assume_role_arn`. Resource của `network/ops` nằm ở account network, còn drift chạy bằng credential CodeBuild ở management với `var.assume_role_arn = ""` và `aws_profile = ""`. Provider đứng nguyên ở management và không thấy resource nào → `plan hong` → `SO_HONG = 1`.

Nên **layer đổi hằng ngày là layer drift chưa bao giờ kiểm được**, mỗi đêm. Và nó đã báo đúng điều đó — `1 layer KHONG kiem duoc` — chỉ là không ai đọc dòng ấy theo nghĩa "drift chưa từng chạy được ở đây". Đây là lý do `SO_HONG` phải đếm riêng (mục 7.6), và là lần nó chứng minh giá trị của mình.

**`catalog_guard` đã cứu một chuyện tệ hơn.** Không có precondition đối chiếu `data.aws_caller_identity.current.account_id` với `local.hub.account_id`, plan có thể *thành công* ở management, không tìm thấy resource nào, rồi báo ~16 resource `to be created` → `SO_DRIFT = 1` → một email nói **có drift thật** cho một layer hoàn toàn bình thường. Buildspec đã phòng đúng kiểu hỏng này cho **tfvars** (*"plan thiếu tfvars sẽ thành công và mô tả một tổ chức không có SCP"*) nhưng chưa phòng cho **danh tính**.

**Cách sửa** (chưa làm): `LAYERS` mang ba trường `layer=key=role` — ARN không chứa `=` nên an toàn — buildspec `cut -d=` ba lần, `export TF_VAR_assume_role_arn` khi có và **`unset` khi không**. Thiếu `unset` thì role của layer này rò sang layer sau trong cùng vòng lặp. Quyền đã đủ: project drift dùng chung `aws_iam_role.codebuild` với stage, vốn có `sts:AssumeRole` sang role mạng.

> **Sau khi destroy network, lỗi này biến mất khỏi tầm nhìn chứ không được sửa.** Chốt `state list = 0` chạy **trước** plan, nên báo cáo đổi thành `state rong`. Nó quay lại đúng lúc mạng được dựng lại.

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
