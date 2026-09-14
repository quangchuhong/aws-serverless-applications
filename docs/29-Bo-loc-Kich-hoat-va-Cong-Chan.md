# Hai bộ phận dùng chung — bộ lọc kích hoạt và cổng chặn

[Doc 28](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) nói năm pipeline hoạt động ra sao. Tài liệu này nói về hai thứ **nằm ngoài mọi pipeline** và được cả năm dùng chung — mỗi thứ **một bản duy nhất**:

| | Ở đâu | Trả lời câu gì |
|---|---|---|
| **Bộ lọc kích hoạt** | [`landing-zone/trigger-filter/`](../landing-zone/trigger-filter/) | thay đổi của bạn có **được chạy** không |
| **Cổng chặn** | [`landing-zone/ops-gate/`](../landing-zone/ops-gate/) | thay đổi của bạn có **được qua** không |

Cả hai đều là một bản dùng chung, và đó là quyết định thiết kế chứ không phải tiện tay. Bảng luật trong `gate.py` **là chính sách an ninh**: "tạo một assignment là nới", "thêm account vào `excluded_accounts` là nới". Khi năm pipeline của mấy phòng ban cùng gọi nó, năm bản sao sẽ lệch nhau — và bản lệch sẽ là bản **lỏng hơn**, vì không ai sửa một luật để nó chặn mình nhiều hơn.

---

## 0. Trạng thái

| | |
|---|---|
| `trigger-filter/lambda/loc.py` | **367 dòng** · `test-loc.py` **39 test** · đã bật thật |
| `ops-gate/gate.py` | **880 dòng** · 37 loại resource có luật · 8 stage trong bảng phạm vi |
| `ops-gate/kiem-log.sh` | **551 dòng** · gọi tự động ở mọi stage Verify |
| `ops-gate/test-gate.py` | **43 test** |
| Chưa | `aws_sns_topic_policy` cố ý không có trong bảng luật — xem Sổ quyết định |

---

## 0b. Bốn file, mỗi file một câu hỏi

Đọc mục này trước. Phần I và II bên dưới là chi tiết của chính bốn file này.

### `ops-gate` KHÔNG phải một layer Terraform

Câu hỏi đầu tiên ai cũng hỏi: *pipeline của nó đâu?* Không có.

```
landing-zone/ops-gate/
  gate.py          36 KB
  kiem-log.sh      20 KB
  test-gate.py     18 KB
```

Không một file `.tf` nào. Không có trong `tf-backend/outputs.tf` (bảng khoá state), không có trong `push-tfvars.sh`. Nên nó **không có** state, tfvars, pipeline, hay cổng duyệt. Nó là một thư viện script nằm trong repo, và các pipeline khác **gọi** nó từ source đã checkout.

"Triển khai" nó chỉ là một việc:

```bash
git push codecommit HEAD:main
```

Ba hệ quả:

1. **Sửa `gate.py` là sửa cho cả năm pipeline, ngay lập tức.** Không rollout từng cái, không ghim phiên bản. Lần chạy tiếp theo của *bất kỳ* pipeline nào dùng bảng luật mới. (`landing-zone/ops-gate/` nằm trong `ban_do` của `ops-network` để ít nhất một pipeline chạy ngay và thử bảng mới — nhưng đó chỉ quyết định *khi nào có một lần chạy*, không quyết định phiên bản nào được dùng.)
2. **`gate.py` vỡ thì pipeline đỏ, không phải đi qua.** Buildspec chạy dưới `set -euo pipefail`, nên một exception Python làm build thất bại. Hỏng theo chiều an toàn.
3. **Nhưng `gate.py` *sai tinh vi* thì pipeline xanh** — một luật không còn nổ, một dòng thiếu trong `PHAM_VI`. Và không pipeline nào chạy `test-gate.py`. Xem cuối mục này.

### `loc.py` — bộ lọc kích hoạt

| | |
|---|---|
| **Nó là gì** | một Lambda trả lời *"thay đổi này có liên quan pipeline nào?"* |
| **Chạy khi nào** | mỗi lần có commit vào `main` của CodeCommit, **trước** khi pipeline nào chạy |
| **Nó đọc** | `GetDifferences(oldCommitId, commitId)` — danh sách file thật, vì sự kiện EventBridge **không** mang danh sách đó |
| **Thấy vấn đề thì** | `ban_do` sai cấu trúc → `raise` **trước** khi chạm pipeline nào · khởi động lẻ thất bại → `raise` để số `Errors` của Lambda hiện ra |

**Ví dụ:** bạn sửa `landing-zone/network/ops/firewall-rules.yaml`. `loc.py` thấy đường dẫn đó khớp tiền tố `"landing-zone/network/"` của `ops-network`, và không khớp tiền tố của bốn pipeline kia — nên chỉ `ops-network` chạy. Không có nó thì cả năm chạy, và bốn cái park bốn phiếu duyệt vô ích.

### `gate.py` — cổng chặn

> **Hai chữ phải hiểu trước khi đọc tiếp: NỚI và THẮT.**
>
> Chúng nói về **quyền**, **không** liên quan gì tới mới/cũ. (`nới` rất dễ đọc nhầm thành `mới` — đã có người đọc nhầm thật.)
>
> | | Nghĩa | Ví dụ |
> |---|---|---|
> | **nới** | sau thay đổi, có thứ **được phép hơn** trước | xoá một SCP Deny · thêm account vào `excluded_accounts` · tạo một ingress rule |
> | **thắt** | sau thay đổi, có thứ **bị chặn hơn** trước | thêm một SCP Deny · xoá một ingress rule · bật lại một Config rule |
>
> **`gate.py` chỉ chặn chiều *nới*.** Chiều *thắt* đi qua tự do, không cần phiếu — bạn không bao giờ phải xin phép để làm hệ thống an toàn hơn.
>
> Hai chỗ ngược trực giác: **xoá** một policy attachment là **nới** (guardrail biến mất, mà policy vẫn tồn tại nên console trông như không có gì đổi), và **tạo** một ingress rule cũng là **nới** (thêm một cái cửa).

| | |
|---|---|
| **Nó là gì** | script trả lời *"thay đổi này làm hệ thống **lỏng hơn** hay **chặt hơn**?"* |
| **Chạy khi nào** | trong stage **Plan**, ngay sau `terraform plan`, **trước** khi có ai duyệt gì |
| **Nó đọc** | `tfplan.json` — **bản kế hoạch**. Không phải code, không phải AWS |
| **Thấy vấn đề thì** | thoát `1` → stage Plan đỏ → pipeline dừng, không tới Apply |

```sh
# buildspec-terraform.yml:268
GATE="${CODEBUILD_SRC_DIR}/landing-zone/ops-gate/gate.py"
if [ ! -f "$GATE" ]; then echo "LOI: khong thay $GATE"; exit 1; fi
python3 "$GATE" --plan tfplan.json --layer "${LAYER_DIR}" --stage "${GATE_STAGE}" --strict $LOOSEN
```

Đường dẫn **tuyệt đối từ gốc repo**, không tương đối từ layer — vì buildspec đã `cd` vào thư mục layer trước đó. Cái `if [ ! -f ]` tồn tại vì đường dẫn đó dễ hỏng khi ai đổi cấu trúc thư mục.

**Ví dụ thật.** Thêm một dịch vụ đối tác vào catalog. Plan sinh ra:

```
+ aws_vpc_security_group_ingress_rule.partner_service["sim-api-v2|172.16.0.0/16"]
```

`gate.py` biết **tạo** một ingress rule là **nới** — mở một cửa — nên nó chặn. Khai vào `ops-loosen.yaml` rồi thì nó in và đi tiếp:

```
NOI co khai bao: aws_vpc_security_group_ingress_rule.partner_service[...]
    ticket TEST-9002 - mở dịch vụ api-v2 cho đối tác sim - duyệt bởi ...
```

### `kiem-log.sh` — bộ đọc log

| | |
|---|---|
| **Nó là gì** | script trả lời *"có cảnh báo nào lọt qua trong một stage trông xanh không?"* |
| **Chạy khi nào** | trong stage **Verify**, cuối cùng, ngay sau script verify của layer |
| **Nó đọc** | CloudWatch Logs của **chính lần chạy này** — `list-pipeline-executions` → `list-action-executions` → `get-log-events` |
| **Thấy vấn đề thì** | thoát khác `0` → stage Verify đỏ |

**Vì sao nó phải tồn tại:** `check` block của Terraform **chỉ cảnh báo** — apply vẫn chạy tiếp, stage vẫn xanh. Một cảnh báo thật sống sót qua một pipeline hoàn toàn xanh, và không ai mở log ra đọc.

**Ví dụ thật:**

```
── Log cua lan chay vua roi
    2380 dong log
    Warning:  1 phat hien / 2 dong
      │ Warning: Check block assertion failed   (x2)
        on firewall.tf line 284, in check "firewall_mode_makes_rules_meaningful":

  CANH BAO log co 1 phat hien (Warning:).
        Stage xanh khong co nghia la khong co gi.
```

Bốn stage trước đó đều xanh. Cảnh báo "firewall đang ở chế độ `alert` nên 7 rule không quyết định gì" chỉ hiện ra vì file này đi tìm nó.

### `test-gate.py` và `test-loc.py` — và chúng chạy ở đâu

| | |
|---|---|
| **Nó là gì** | 43 + 39 test dựng dữ liệu **giả** bằng tay rồi kiểm từng luật, từng chiều |
| **Chạy khi nào trong pipeline** | **không bao giờ** |

```bash
python3 landing-zone/ops-gate/test-gate.py        # 43 dat / 0 truot
python3 landing-zone/trigger-filter/test-loc.py   # 39/39 dat
python3 landing-zone/kiem-module.py               # 18 phep kiem
```

Cả ba chỉ xuất hiện trong **chú thích** của code hạ tầng, không ở một lệnh nào của pipeline. Nên chúng chạy **duy nhất trên máy của người sửa**.

Đó là lỗ thật, và nó ghép với hệ quả 2 và 3 ở trên: một `gate.py` *vỡ* thì đỏ (an toàn), nhưng một `gate.py` *sai tinh vi* thì **xanh**, và cổng im lặng ngừng chặn đúng cái nó được viết ra để chặn. Đã xảy ra hai lần: phép kiểm 18 ban đầu chỉ đọc một nửa (xanh cho đúng cấu hình làm pipeline đỏ), và phép kiểm 14 từng tự đi qua chính nó (chuỗi cần tìm nằm trong chú thích vừa viết).

Chỗ đúng để bịt là stage `Lint` — nó chạy offline, không gọi AWS, và đứng trước mọi thứ chạm AWS. Cơ chế đã có sẵn: `lint_jobs = join(";", [for c in var.catalogs : "${c.layer}=${c.lint}"])`. Chưa làm.

### Trong một lần chạy, chúng nằm ở đâu

```
commit vào main
   │
   loc.py ──► chỉ những pipeline bị chạm
   │
   ▼
Nguồn → Lint → Expiry → ┌ Plan ──── Duyệt ── Apply ┐ → Verify
                        │   │                      │      │
                        │   gate.py                │      kiem-log.sh
                        └──────────────────────────┘      (đọc log của
                                                           chính lần chạy này)

test-gate.py · test-loc.py · kiem-module.py
   └─ không ở đâu trong hình này. Chỉ trên máy bạn.
```

| File | Đọc gì | Trả lời câu gì | Chặn ở đâu |
|---|---|---|---|
| `loc.py` | danh sách file đã đổi | pipeline nào **liên quan** | trước khi pipeline chạy |
| `gate.py` | bản plan | thay đổi này làm **lỏng hơn** hay **chặt hơn** | trước Duyệt và Apply |
| `kiem-log.sh` | log của lần chạy này | có cảnh báo nào **lọt** không | sau Apply |
| `test-*.py` | dữ liệu giả | ba file trên còn đúng không | không ở đâu |

Điểm dễ nhầm nhất: **`gate.py` đọc kế hoạch, `kiem-log.sh` đọc quá khứ.** Cái đầu chặn trước khi chuyện xảy ra; cái sau nói cho bạn biết chuyện gì vừa xảy ra mà không ai kêu. Và **không cái nào đọc AWS** — việc đó là của `verify.sh` từng layer, chạy ngay trước `kiem-log.sh` (doc 28 mục 6).

---

# Phần I — `trigger-filter`

## 1. Vì sao nó tồn tại

Rule EventBridge của riêng một pipeline **không lọc được theo đường dẫn**. Không phải vì viết sai — vì sự kiện `CodeCommit Repository State Change` chỉ mang:

```
repositoryName   commitId   oldCommitId   referenceName
```

Không có danh sách file. Nên một dòng sửa trong `docs/` làm **cả năm** pipeline chạy, và mỗi cái park một phiếu duyệt.

Bộ lọc là một Lambda đứng giữa: nó gọi `GetDifferences(oldCommitId, commitId)` để lấy danh sách file thật, rồi chỉ `StartPipelineExecution` những pipeline có tiền tố bị chạm.

```
CodeCommit event  ─►  EventBridge  ─►  Lambda loc.py  ─►  StartPipelineExecution
                                          │                (chỉ pipeline bị chạm)
                                          └─ GetDifferences(truoc, sau)
```

**Thứ tự bật không đảo được:** bật `trigger-filter` **trước**, rồi mới đặt `tu_kich_hoat = false` ở từng pipeline. Làm ngược lại thì giữa hai lần apply không có gì kích hoạt pipeline nào — và đó là kiểu hỏng không có triệu chứng.

## 2. `ban_do` và `tru`

```hcl
ban_do = {
  "ops"                = ["landing-zone/organization/"]
  "ops-trail"          = ["landing-zone/org-trail/"]
  "ops-permission-set" = ["landing-zone/permission-sets/"]
  "ops-config-rules"   = ["landing-zone/config-detective/"]
  "ops-network"        = ["landing-zone/network/", "landing-zone/ops-gate/"]
}

tru = {
  "vending" = ["landing-zone/network/ops/"]
}
```

Khoá là tên **ngắn**. Tên đầy đủ do Terraform ghép `"${var.project}-${khoá}"` — viết ngắn ở đây để một lần gõ sai tiền tố project không thể xảy ra: bản đồ và pipeline lấy tiền tố từ **cùng một biến**.

Giá trị là danh sách **tiền tố chuỗi**, không phải glob. Bốn cách viết, bốn nghĩa:

| Viết | Nghĩa |
|---|---|
| `"landing-zone/network/"` | đúng — có `/` nên không bắt `landing-zone/network-cu/` |
| `"landing-zone/network"` | bắt luôn `landing-zone/network-cu/...` |
| `""` | chạy với **mọi** thay đổi — hợp lệ, nhưng phải có chủ đích |
| `[]` | pipeline **không bao giờ chạy** — `startswith(())` luôn `False` |

Dòng cuối là cái đáng sợ nhất: một danh sách rỗng **đọc giống "chưa điền" và chạy giống "đã tắt"**. `loc.py` coi đó là lỗi cứng, và thông báo nói thẳng cách viết đúng: *muốn nó chạy với mọi commit thì khai `[""]`, không phải `[]`*.

### Vì sao cần `tru`

Vì layer lồng nhau. `landing-zone/network/` và `landing-zone/network/ops/` là hai layer, hai state, hai pipeline. So khớp là so khớp **chuỗi**, nên tiền tố của cha bắt cả mọi file của con. **Không có cách nào viết một tiền tố nghĩa là "network/ nhưng không network/ops/"** — nên phải trừ ra.

Không khai thì mỗi lần sửa lớp vận hành mạng — thứ đổi **hằng ngày** — sẽ kéo `vending` chạy vô ích, kèm một cổng duyệt treo mang nhãn "tạo account". Đó không phải lỗi, chỉ là ồn — và ồn lâu thì người ta thôi đọc.

## 3. Năm phép kiểm cấu trúc, chạy MỖI lần

`kiem_ban_do()` chạy trước khi chạm vào pipeline nào. Có lỗi thì Lambda **ném ngay**, không khởi động gì:

```python
loi, kiem = kiem_ban_do(ban_do, tru, tien_to_phu)
if loi:
    # Nem TRUOC khi cham vao pipeline nao: mot ban do sai thi khong
    # co ket qua nao cua no dang tin, ke ca phan "khop".
    raise RuntimeError("BAN_DO sai:\n  " + "\n  ".join(loi))
```

| # | Kiểm gì | Cái nó bắt |
|---|---|---|
| 1 | `ban_do` không rỗng | một bộ lọc **chặn sạch mọi thay đổi**, đọc như "chưa cấu hình" |
| 2 | mỗi pipeline có ít nhất một tiền tố | pipeline không bao giờ chạy |
| 3 | tên trong `ban_do` là pipeline **có thật** ở AWS | gõ sai tên — không sửa được bằng cách thử lại, nên phải ồn ào |
| 4 | `tru` không gọi tên pipeline ngoài `ban_do` | ngoại lệ đã hết hạn, nằm đó vô nghĩa |
| 5 | `tru` không **chặn sạch** một tiền tố gom | xem dưới |
| + | **độ phủ** — mọi pipeline mang tiền tố `${project}-` đều có trong bản đồ | pipeline bị quên: vẫn tồn tại, vẫn xanh, **không bao giờ chạy nữa** |

Phép 5 là phép khó thấy nhất, vì **hai dòng đều có nội dung** và phải đọc cả hai mới biết dòng sau vô hiệu hoá dòng trước:

```hcl
ban_do = { "x" = ["landing-zone/network/"] }
tru    = { "x" = ["landing-zone/"] }        # gom không bao giờ khớp nữa
```

Phép độ phủ là chiều nguy hiểm nhất, và nó chỉ bảo đảm **đúng một điều**: *"mọi pipeline có tên bắt đầu bằng `tien_to_phu` đều có trong `ban_do`"* — **không** phải "mọi pipeline của landing zone". Hai câu đó trùng nhau chỉ vì tên pipeline do Terraform ghép từ `local.name = "${var.project}-${var.ten}"`. Một pipeline đặt tên tay sẽ lọt.

## 4. Fail-open: khi nào nó chạy hết, và vì sao

Bộ lọc này là một **điểm hỏng đơn**: nó hỏng thì không pipeline nào chạy. Nên với mọi thứ nó **đoán trước được**, nó chọn chạy hết thay vì chạy không:

| Tình huống | Hành vi |
|---|---|
| sự kiện thiếu `repositoryName` hoặc `commitId` | **chạy hết** |
| không có `oldCommitId` (nhánh vừa được tạo) | **chạy hết** |
| `GetDifferences` lỗi | **chạy hết** |
| diff **rỗng thật** (commit rỗng, merge không đổi gì) | **không chạy gì** |

Dòng cuối là một phân biệt quan trọng, và nó đúng chiều với mọi thứ khác trong hạ tầng này:

```python
# Diff rong that su xay ra: commit rong, hoac merge khong doi gi.
# Khong co gi de chay, va do la ket luan DOC DUOC chu khong phai
# mot phep doc hong - nen o day khong fail open.
```

**Một phép đọc hỏng ≠ một câu trả lời "không có gì".** Cùng nguyên tắc với `SO_HONG` của job drift (doc 28 mục 7.6) và với `kiem-mang.sh` khi không đọc được `list-rule-groups`.

## 5. "Đạt" và "không chạy" phải trông khác nhau

Hai phép kiểm cần gọi AWS (số 3 và độ phủ). Nếu `ListPipelines` lỗi thì chúng không chạy được. Bản đầu tiên trả về `loi` rỗng trong **cả hai** trường hợp — đạt, và không chạy — và thứ duy nhất phân biệt là một dòng `CANH BAO` trong log.

Một lần chạy thật cho thấy vấn đề: kết quả ra `{"loc": true, ...}` và **không có cách nào biết** phép kiểm độ phủ đã chạy hay đã im lặng biến mất. Phải mở log, và phải biết **trước** là cần tìm dòng nào.

Đó đúng là khuyết điểm mà cả file này được viết ra để chống. Nên trạng thái đi theo **giá trị trả về**, không chỉ nằm trong log:

```python
return loi, f"THIEU: khong liet ke duoc pipeline ({type(e).__name__})"
```

Và trường `kiem_ban_do` được gắn vào kết quả ở **mọi** đường trả về, kể cả đường fail-open — vì câu hỏi "hai phép kiểm cần AWS có chạy không" không phụ thuộc vào việc đọc được diff hay không.

## 6. Vì sao Lambda phải `raise`

Khởi động một pipeline có thể thất bại lẻ. Khi đó Lambda **nén lỗi**, không trả về êm:

```python
if hong:
    raise RuntimeError("Khoi dong khong tron ven:\n  " + ...)
```

Lý do: **số `Errors` của hàm này là chỗ duy nhất việc "một pipeline không khởi động được" lộ ra.** Log thì không ai đọc.

EventBridge sẽ gọi lại (mặc định 2 lần). Lần gọi lại khởi động **lại** những pipeline đã chạy — vô hại, vì CodePipeline thay bản đang chờ bằng bản mới. Đổi lại là một tên gõ sai sẽ kêu ba lần thay vì một. Đánh đổi có chủ đích.

## 7. `test-loc.py` — 39 test, offline

Không gọi AWS. Kiểm toàn bộ tổ hợp `ban_do` × `tru` × danh sách đường dẫn, và cả các nhánh fail-open. Chạy được trên máy:

```bash
python3 landing-zone/trigger-filter/test-loc.py
```

---

# Phần II — `ops-gate`

## 8. `gate.py` — hai bảng, hai câu hỏi khác nhau

```bash
python3 landing-zone/ops-gate/gate.py \
  --plan tfplan.json \
  --layer landing-zone/network/ops \
  --stage cloudops-firewall \
  --strict [--loosen ops-loosen.yaml]
```

Nó đọc `terraform show -json tfplan`, tức **bản plan**, không phải code và không phải AWS.

| Bảng | Trả lời câu gì | Thiếu thì sao |
|---|---|---|
| `PHAM_VI` | stage này **được phép** đổi những gì | chỉ **cảnh báo** "stage không có trong bảng" — tức không kiểm được phạm vi mà vẫn xanh |
| `LUAT` | thay đổi này **nới** hay **thắt** | loại resource không có trong bảng thì **bỏ qua hoàn toàn** |

`PHAM_VI` nhận cả hai dạng, và sự khác nhau là quan trọng:

```python
cho_type     = {p for p in pham_vi if "." not in p}   # "aws_route53_record"
cho_dia_chi  = tuple(p for p in pham_vi if "." in p)  # "aws_organizations_policy.scp"
```

Dạng **địa chỉ** là cách tách hai stage dùng cùng một loại resource:

```
aws_organizations_policy.scp   →  stage sec-scp
aws_organizations_policy.tag   →  stage sec-tagging
```

Khớp theo type thì hai stage đó có phạm vi **giống nhau**, tức stage `tagging` được phép sửa SCP — đúng cái mà `PHAM_VI` tồn tại để chặn.

**Khoá stage phải duy nhất toàn cục** và mang tiền tố chủ sở hữu (`sec-`, `cloudops-`), vì bảng này là **một bản dùng chung**. Hai pipeline cùng có stage tên `ou` sẽ đè lên nhau, và cái bị đè lặng lẽ nhận phạm vi của cái kia.

## 9. Sáu phép so sánh — và bốn luật ngầm chạy trước chúng

Bảng `LUAT` không đếm resource. Nó đọc `before`/`after` của **từng thuộc tính**:

```python
"aws_guardduty_organization_configuration": {
    "thuoc_tinh": {
        "auto_enable_organization_members": ("thu_tu:ALL>NEW>NONE", "..."),
    },
},
```

Trước khi tới phép so sánh, bốn luật ngầm áp cho mọi thuộc tính:

| Trước | Sau | Kết luận |
|---|---|---|
| không có | không có | không phải nới |
| không có | có | **không** phải nới — chưa có → có thì không thể là nới |
| có | **không còn** | **NỚI** — bỏ một thuộc tính là để nó về mặc định của AWS, và mặc định của AWS gần như luôn lỏng hơn |
| kiểu luật không nhận ra | | **BÁO LỖI** — `"KIEU LUAT KHONG BIET"` |

Luật thứ ba là luật tinh nhất trong cả file: xoá một dòng cấu hình **không** phải là "không đổi gì". Luật thứ tư thì chống chính người viết luật — một lần gõ sai tên kiểu sẽ làm cả luật đó **biến mất trong im lặng**, nên nó phải kêu.

Sáu phép so sánh:

| Phép | Nới khi | Dùng cho |
|---|---|---|
| `bool_phai_true` | `true` → khác `true` | `block_public_policy`, `ignore_public_acls`, `is_enabled`… |
| `so_khong_giam` | số **giảm** | số ngày giữ log, capacity… |
| `chuoi_phai_la:X` | `X` → khác `X` | `"Enabled"` |
| `thu_tu:A>B>C` | đi **xuống** bảng xếp | `ALL>NEW>NONE`, `ENABLED>DISABLED`, `DEFAULT>NONE` |
| `tap_khong_lon` | tập **lớn lên** | `excluded_accounts` và các danh sách miễn trừ |
| `bat_ky_doi` | đổi bất cứ gì | khi cổng **không hiểu** nội dung — ví dụ inline policy của permission set |

### `thu_tu:` tồn tại vì phép so chuỗi nói ngược

```
"NONE" > "ALL"   theo thứ tự chữ cái
```

Nên một phép so chuỗi thông thường sẽ coi việc **tắt GuardDuty** là một bước **thắt**. Bảng xếp hạng tường minh là cách duy nhất để chiều đúng.

### `tap_khong_lon` — chiều ngược trực giác

Một tập hợp **lớn lên** lại là nới lỏng. Mỗi account thêm vào `excluded_accounts` là một account **thoát khỏi** phép kiểm — và nó thoát trong im lặng: rule vẫn "đang bật", console vẫn hiện nó xanh.

Cùng loại: **tạo** một `aws_vpc_security_group_ingress_rule` là nới (mở một cửa), trong khi trực giác nói `create` là thêm chứ không phải bớt.

### Không so sánh được thì PHẢI nói ra

Cả `so_khong_giam` và `thu_tu:` đều có nhánh này:

```python
if a is None or b is None:
    # Khong so sanh duoc thi PHAI noi ra, khong duoc im lang bo qua:
    # mot phep so hong tra ve "khong co gi" doc giong het "khong co
    # thay doi".
    if v_truoc != v_sau:
        return f"{duong_dan}: {v_truoc!r} -> {v_sau!r}, khong so sanh duoc nhu so - {vi_sao}"
```

Đây là cùng một nguyên tắc với fail-open của bộ lọc và với `SO_HONG` của drift, xuất hiện lần thứ ba: **một phép đọc hỏng không được trả về cùng kết quả với một câu trả lời sạch.**

## 10. Bốn nguyên tắc của bảng `LUAT`

**Mỗi luật phải mang lý do, và lý do nói về *hậu quả*, không về cơ chế.**

```python
"aws_organizations_policy_attachment": {
    "xoa_la_noi": "mot guardrail khong con gan vao dau - policy van ton tai nen no trong nhu khong co gi doi",
},
"aws_sns_topic_subscription": {
    "xoa_la_noi": "mot nguoi nhan bao dong bien mat - phat hien van sinh ra, chi khong den voi ai",
},
```

Lý do đó in ra cho người đọc bản plan. `"xoá attachment"` không giúp ai; `"guardrail không còn gắn vào đâu, và policy vẫn tồn tại nên nó trông như không có gì đổi"` thì có.

**Đường báo động cũng là guardrail.** Phần `config-detective` trong bảng có chú thích riêng, vì nó dễ sót nhất:

> Phần này dễ sót nhất, vì nó không phải "phép kiểm" nên không ai nghĩ nó là guardrail. Nhưng một phát hiện không đến được với ai thì bằng một phát hiện không xảy ra — và khác biệt duy nhất là nó có trong bảng điều khiển.

**Cổng không hiểu nội dung policy, và nói ra điều đó.** `aws_ssoadmin_permission_set_inline_policy` dùng `bat_ky_doi` với lý do ghi thẳng *"phải đọc bằng mắt, cổng này không hiểu nội dung policy"*. Thà chặn mọi thay đổi và bắt người đọc, hơn là giả vờ phân tích được JSON policy.

**Loại không có trong bảng thì đi qua hoàn toàn.**

```python
luat = LUAT.get(rc["type"])
if luat is None:
    return []
```

Đó là lựa chọn, và nó có nghĩa: mỗi resource mới đưa vào phạm vi một stage phải được cân nhắc xem có cần luật hay không.

## 11. Khai báo nới lỏng

```yaml
# <layer>/ops-loosen.yaml
loosen:
  - stage: cloudops-firewall
    address: aws_vpc_security_group_ingress_rule.partner_service["sim-api-v2|172.16.0.0/16"]
    ticket: TEST-9002
    reason: mở dịch vụ api-v2 cho đối tác sim
    approved_by: ai@day.com
```

Bốn trường đều bắt buộc. Không có PR thì không có chỗ nào tự nhiên để một thay đổi bị đọc bởi người thứ hai — **file này là thứ thay cho diff của PR**.

Trường `stage` bắt buộc khi layer có từ **hai** stage. `ops-loosen.yaml` là *một* file cho cả layer, nhưng `gate.py` chạy theo *từng* stage với một bản plan đã `-target`. Nên một khai báo cho stage A là "không dùng tới" dưới mắt stage B, và `--strict` biến cảnh báo đó thành một lần đỏ. Đã xảy ra thật ở `ops-network`: khai báo của `cloudops-firewall` giết stage `cloudops-network` dù bản plan của nó sạch. `kiem-module.py` phép kiểm 16 giữ chỗ này.

**Vòng bốn nhịp:**

| Nhịp | Việc | Kết quả |
|---|---|---|
| 1 | push thay đổi nới | **chặn** |
| 2 | khai `loosen` + push | qua, apply được |
| 3 | **xoá khai báo** + push | qua — cửa đã đóng |
| 4 | quên xoá | lần chạy **sau** đỏ: "khai báo không dùng tới" |

Nhịp 4 là cố ý. Một cánh cửa để mở làm pipeline đỏ **tự nó**, chứ không chờ ai nhớ ra.

**Nới lỏng không cấp phép cho xoá.** `loosen` chỉ nói chuyện với `gate.py`. `FAIL_ON_DESTROY` là một phép đếm trong shell chạy *sau* đó và không đọc file khai báo (doc 28 mục 3.2).

## 12. `--strict` và mã thoát

```python
if loi or (a.strict and canh_bao):
    return 1
```

Không có `--strict` thì cảnh báo chỉ là cảnh báo. Pipeline **luôn** truyền `--strict`, nên trong pipeline mọi cảnh báo là lỗi. Chạy tay trên máy thì bỏ `--strict` để xem trước mà không bị chặn.

Bản in ra có bốn khối, theo thứ tự: danh sách resource thay đổi → `NOI co khai bao` (kèm ticket, reason, approved_by) → `CANH BAO` → `LOI`.

## 13. `kiem-log.sh` — lớp đọc log của lần chạy vừa rồi

`buildspec-verify.yml` gọi nó **luôn**, sau lệnh verify của layer. Nó tồn tại vì một lý do cụ thể: **`check` block chỉ cảnh báo, nên một cảnh báo thật sống sót qua một pipeline hoàn toàn xanh.**

```
PIPELINE=<ten> ./kiem-log.sh      # LOG_GROUP mặc định /aws/codebuild/$PIPELINE
```

Thiếu `PIPELINE` là **lỗi**, không phải "không có gì để làm" — và thông báo chỉ thẳng `codebuild.tf` phải đặt biến đó cho project verify.

Nó đọc execution mới nhất qua `list-pipeline-executions`, lấy các action qua `list-action-executions`, rồi `get-log-events` từng stream. Bốn quyền đó phải có trong role CodeBuild; `kiem-module.py` phép kiểm 14 đối chiếu: caller nào khai `verify` thì phải cấp đủ bốn.

### Bốn cái bẫy nó phải tránh, cả bốn đã sập

**ANSI escape.** Terraform tô màu đầu ra. Không strip thì mọi mẫu so khớp đều trượt, và bộ đọc báo "không có gì" cho một log đầy cảnh báo.

**Văn bản tài liệu bị khớp như dữ liệu.** `terraform output` in ra heredoc chứa chữ `Warning:`; CodeBuild echo lại nguyên văn lệnh nó đang chạy; `externalExecutionSummary` lặp lại nội dung. Bốn cửa khác nhau, cùng một kiểu hỏng — kể cả chính bộ đọc từng khớp vào **chú thích của chính nó**.

**Assertion không có nội dung.** `Check block assertion failed` trơ trọi thì vô dụng. `chi_tiet()` đọc thêm một cửa sổ 30 dòng cùng stream, cắt đúng khung `│`, bỏ các khối giá trị lồng nhau, rồi in dòng `on <file> line N` cùng hai dòng cuối.

**Một bộ lọc dựa trên giả định sai.** Có lúc bộ đọc bỏ qua mọi thứ sau `Outputs:`, dựa trên giả định *"cảnh báo in trước output"*. Giả định đó sai — một build có **hai** lần apply — và nó nuốt một cảnh báo thật. Chỉ phát hiện được bằng cách so hai con số tổng: `1711 = 1711`. Bộ lọc đã bị **bỏ đi**.

Kết quả in ra dạng `N phat hien / M dong`, gộp trùng theo `(160 ký tự đầu, chi tiết)` và đánh `(xN)`.

## 14. `test-gate.py` — 43 test, offline

Không gọi AWS, không cần Terraform. Nó dựng `tfplan.json` giả bằng tay và kiểm từng phép so sánh, từng chiều, cùng cơ chế nới lỏng.

Hai test đáng chú ý vì chúng kiểm **chính bộ kiểm**:

- Một test đối chiếu **nhãn** của mỗi test với tham số `stage=` truyền vào. Chúng từng lệch nhau: nhãn ghi `stage B-scp` trong khi khoá đã là `sec-scp`, và không phép kiểm nào thấy vì test vẫn xanh. Một nhãn sai làm người đọc kết quả đi tìm một stage không tồn tại.
- Bốn test cho chốt an toàn: `terraform_data.catalog_guard` / `scp_guard` phải **qua được** cổng ở ba stage (`cloudops-network`, `cloudops-firewall`, `sec-scp`), cộng **một test chiều ngược** — một `terraform_data` khác tên phải bị **từ chối**. Test chiều ngược là thứ giữ cho `PHAM_VI` khai dạng địa chỉ chứ không dạng type: cho cả type `terraform_data` nghĩa là mọi `terraform_data` tương lai cũng qua, kể cả một cái mang `provisioner` chạy lệnh cục bộ trong CodeBuild.

```bash
python3 landing-zone/ops-gate/test-gate.py       # 43 đạt / 0 trượt
```

---

## Sổ quyết định

| Quyết định | Lý do |
|---|---|
| `gate.py` nằm ngoài mọi thư mục pipeline | bảng `LUAT` là chính sách an ninh; nhiều bản sao sẽ lệch, và bản lệch sẽ là bản **lỏng hơn** |
| Khoá stage mang tiền tố chủ sở hữu | `PHAM_VI` là một bảng dùng chung; hai stage trùng tên đè nhau |
| `PHAM_VI` khai chốt an toàn dạng **địa chỉ** | cho cả type `terraform_data` nghĩa là một cái mang `provisioner` cũng qua được |
| Kiểu luật không nhận ra → **báo lỗi** | một lần gõ sai tên kiểu làm cả luật biến mất trong im lặng |
| Thuộc tính bị **bỏ** khỏi cấu hình = nới | nó về mặc định của AWS, và mặc định của AWS gần như luôn lỏng hơn |
| Bộ lọc **fail-open** với mọi lỗi đoán trước được | nó là điểm hỏng đơn: hỏng thì không pipeline nào chạy |
| Nhưng diff **rỗng thật** thì **không** fail-open | đó là kết luận đọc được, không phải một phép đọc hỏng |
| Lambda `raise` khi khởi động lẻ thất bại | số `Errors` là chỗ **duy nhất** việc đó lộ ra; log thì không ai đọc |
| Trạng thái phép kiểm đi theo **giá trị trả về** | "đạt" và "không chạy" từng cùng trả về rỗng, và chỉ khác nhau một dòng log |
| `aws_sns_topic_policy` **không** có trong bảng `LUAT` | thêm Principal vào topic policy *là* nới quyền liên account, nhưng phạm vi cổng duyệt đã chốt ở ba loại (SCP, permission set, firewall rule). Thêm loại thứ tư là đổi mô hình vận hành, không phải sửa một bộ kiểm — lý do ghi ở commit `d276cad` |

---

## Liên quan

- [Doc 28 — Pipeline vận hành LZ](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) — năm pipeline, sáu lớp kiểm, và dựng một pipeline mới
- [Sơ đồ tổng quan — Luồng pipeline Landing Zone](https://claude.ai/code/artifact/efa04c8c-f8a3-4cae-9a97-250e75fdd1f9) — hình 1 là đường kích hoạt, hình 4 là vòng bốn nhịp
- [Doc 22 — Nhật ký triển khai LZ DIY](./22-Nhat-ky-Trien-khai-LZ-DIY.md) — từng lỗi, theo thứ tự gặp
- [`landing-zone/trigger-filter/README.md`](../landing-zone/trigger-filter/README.md)
