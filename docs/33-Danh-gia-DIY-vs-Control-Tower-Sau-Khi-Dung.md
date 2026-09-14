# Đánh giá: DIY vs Control Tower — trạng thái thật sau khi dựng

[Doc 21](./21-Control-Tower-vs-DIY.md) so sánh **thiết kế guardrail**: SCP của DIY đối chiếu với controls của CT, và cách port ba loại control sang. Nó vẫn đúng, và tài liệu này không lặp lại nó.

Đây là đánh giá **trạng thái thật sau khi đã dựng xong** cả nền tảng và đường vận hành: cái gì ngang CT, cái gì hơn, cái gì thiếu. Mỗi mục "thiếu" kèm lệnh để bạn tự kiểm lại — một đánh giá không kiểm lại được thì chỉ là một ý kiến.

---

## 0. Kết luận ngắn

| Trục | So với Control Tower |
|---|---|
| **Nền tảng** — org, OU, SCP, logging, identity, network | **ngang hoặc hơn** |
| **Vận hành** — pipeline, cổng chặn, drift, verify | **hơn rõ rệt** — CT không có gì tương đương |
| **Độ phủ tính năng bảo mật** | **kém**, và kém theo hai cách khác nhau (mục 5 và 6) |
| **Khả năng duy trì bởi người khác** | **kém rõ rệt** — đây là nhược điểm thật, không sửa được bằng code |

**Chưa đầy đủ.** Thiếu bốn nhóm tính năng mà audit thường hỏi, và — đáng chú ý hơn — có bốn cơ chế **đã đi dây xong nhưng công tắc đang ở số không**, làm khoảng cách với CT trông rộng hơn thực tế.

---

## 1. Phương pháp — vì sao tin được danh sách này

Danh sách "thiếu" ở mục 6 không lấy từ một checklist chung. Nó là kết quả grep trên chính repo, và bạn chạy lại được:

```bash
cd landing-zone
for t in aws_backup aws_accessanalyzer aws_inspector2 aws_macie2 \
         flow_log aws_ssm_patch aws_servicequotas RequestedRegion; do
  printf "%-24s %s\n" "$t" "$(grep -rl "$t" */*.tf */*/*.tf */catalog/*.yaml 2>/dev/null | tr '\n' ' ')"
done
```

Còn các con số về trạng thái đang chạy lấy từ `terraform output` của những lần apply thật, không từ code:

```bash
cd landing-zone/config-detective && terraform output security_hub guardduty recording_scope
cd ../network/ops               && terraform output summary
```

---

## 2. Ba trục, không phải một

So sánh "DIY vs CT" thành một câu là chỗ dễ sai nhất, vì ba trục đi ngược nhau.

### Trục 1 — Nền tảng: ngang hoặc hơn

| | Bản này | CT |
|---|---|---|
| Organization + cây OU | ✓ hai tầng, catalog YAML | ✓ |
| SCP | 4 policy, gồm region deny (`RequestedRegion`) | ✓ controls |
| CloudTrail cấp tổ chức | ✓ + **object lock** ở log-archive | ✓ |
| Config + aggregator | ✓ 10 org rule, 2 region | ✓ |
| Identity Center + permission set | ✓ | ✓ |
| Log archive account riêng | ✓ | ✓ |
| Account vending | ✓ `vending-pipeline` 7 stage | ✓ AFT |
| **Network** | ✓ TGW hub-spoke, centralized egress/ingress, Network Firewall, DNS profile, VPN đối tác | **✗ CT làm số không** |

Dòng cuối là chỗ chênh lệch lớn nhất theo hướng có lợi: dùng CT thì toàn bộ phần mạng **vẫn phải tự làm**.

### Trục 2 — Vận hành: hơn rõ rệt

Đây là phần CT không có gì tương đương, và cũng là phần dựng gần đây nhất.

| Năng lực | Bản này | CT |
|---|---|---|
| Đọc một bản plan và phân loại **nới / thắt** | `gate.py`, 37 loại resource có luật chiều | ✗ |
| Nới quyền phải có **ticket + lý do + người duyệt** trong repo | `ops-loosen.yaml`, vòng bốn nhịp | ✗ |
| Cổng duyệt người **giữa plan và apply** | ✓ `approve_stages` | ✗ |
| Kiểm chứng bằng cách **đọc AWS**, không đọc state | 7 script verify | ✗ (dashboard đọc Config) |
| Drift phát hiện theo lịch, **không có nhánh apply** | ✓ mỗi pipeline một job | ✓ (LZ drift, phạm vi hẹp hơn) |
| Bắt cảnh báo lọt qua một stage **xanh** | `kiem-log.sh` | ✗ |
| 126 `check` mã hoá kiến thức tổ chức | ✓ | ✗ |

Ví dụ một `check` mà CT không thể có, vì nó đặc thù cho tổ chức bạn:

> `suspended_ou_is_actually_frozen` — một OU tên "Suspended" mà không có SCP đóng băng gắn vào là **một cái tên nói dối**.

### Trục 3 — Độ phủ tính năng: kém

CT bật cho bạn hàng trăm detective control ngày đầu. Ở đây có 10 Config rule và 0 Security Hub standard. Xem mục 5 và 6.

---

## 3. Ưu điểm

**Của DIY nói chung:**

- Không bị ràng buộc cấu trúc OU/region của CT, và **không có trạng thái "landing zone needs update"** chặn thay đổi.
- Một toolchain duy nhất. Không có nửa hạ tầng nằm ngoài state.
- Chạy được ở region/partition CT không hỗ trợ.
- Không có đường "rơi ra khỏi CT" — cái mà tổ chức dùng CT sợ nhất.

**Của riêng bản này:**

- **126 `check` trên 413 resource** — gần một check cho mỗi ba resource. Phần lớn sinh ra **sau một lần hỏng im lặng**, nên chúng là kiến thức đã trả giá.
- **Catalog YAML với `ticket` và `expires`.** Mở một port là sửa một khối YAML; người xin không cần biết CIDR, vì `main.tf` giải tên app → CIDR.
- **Bốn buildspec, mỗi cái định nghĩa bằng cái nó KHÔNG có**: lint không gọi AWS, verify không có Terraform/state/tfvars, drift **không có nhánh apply** — *không phải vì một biến, mà vì đoạn code đó không tồn tại*.
- **Tài liệu.** Doc 28–32 cộng RUNBOOK 16 giai đoạn. Đây là thứ bù trực tiếp cho nhược điểm lớn nhất ở mục 4.

---

## 4. Nhược điểm

**Của DIY nói chung:**

- **Không có đường nâng cấp được quản lý.** CT ship control mới theo thời gian; ở đây phải có người đọc Control Catalog rồi port tay.
- **AWS Support không debug được** cái bạn tự viết.
- Thuê một kỹ sư biết CT thì họ làm được ngay.

**Của riêng bản này — và đây là phần quan trọng hơn:**

| Nhược điểm | Mức độ |
|---|---|
| **Bus factor.** Logic quan trọng nhất nằm trong `gate.py` (880 dòng) và `loc.py` (367 dòng), chú thích tiếng Việt, 22 script bespoke | **nghiêm trọng** — không sửa được bằng code |
| **Ba bộ test không chạy trong pipeline.** 43 + 39 + 18 phép kiểm chỉ chạy trên máy người sửa | cao |
| **Drift mù đúng layer đổi nhiều nhất.** Job drift không kiểm được `network/ops` vì project drift thiếu `ASSUME_ROLE_ARN` | cao |
| **`OrganizationAccountAccessRole` full admin ở ba account đích**, và pipeline assume vào đó hằng ngày | trung bình |
| **`LAYERS` rỗng = báo cáo sạch.** Tắt stage thì job drift vẫn chạy, lặp 0 vòng, in `Moi layer khop state` | trung bình |
| Phát hiện thuần, **không auto-remediation** | trung bình |

Ba dòng giữa là thứ tìm ra **trong lúc viết tài liệu**, không phải trong lúc dùng. Điều đó nói lên một điểm yếu của cả cách làm: một hệ thống bespoke thì lỗi của nó chỉ lộ ra khi có người đọc lại.

---

## 5. Cơ chế đã đi dây, công tắc đang ở số không

Đây là phần đáng chú ý nhất của cả đánh giá, vì nó nói khoảng cách với CT **hẹp hơn** vẻ ngoài — nhưng chỉ khi có người bật.

| Cơ chế | Trạng thái thật | Bật bằng gì |
|---|---|---|
| **Security Hub standards** | `enabled = true`, **14 member**, `standards = []` | `security_hub_standards = ["fsbp"]` |
| **GuardDuty features** | bật, 14 member, và **cả 6 feature đều tắt**: `EBS_MALWARE_PROTECTION`, `EKS_AUDIT_LOGS`, `LAMBDA_NETWORK_LOGS`, `RDS_LOGIN_EVENTS`, `RUNTIME_MONITORING`, `S3_DATA_EVENTS` | `guardduty_features` |
| **Tag policy** | gắn, nhưng `report-only` | `enforced_for` |
| **Network Firewall** | 7 rule được nạp, chế độ `alert` → **không chặn gì** | `firewall_mode = "drop"` ở layer cha |

Dòng đầu là **khoảng cách lớn nhất với CT, và nó là một dòng tfvars.** Biến `security_hub_standards` đã nhận sẵn `fsbp`, `cis-1.4`, `cis-3.0`, `nist-800-53`, `pci-dss`. Doc 21 mục 6 đã nói đúng đòn bẩy này:

> Port tay từng detective control của CT là việc vô nghĩa. Đường ngắn hơn: bật **Security Hub standard** ở cấp tổ chức. `AWS Foundational Security Best Practices` gói sẵn phần lớn detective control của CT, bật một lần phủ mọi account.

Cả bốn công tắc đều tắt **có lý do** — chi phí, và giai đoạn rollout. `check.security_hub_costs_money` và `check.guardduty_features_cost_money` tồn tại đúng để nhắc điều đó. Nhưng "tắt có lý do" và "tắt vì quên" trông giống nhau sau sáu tháng, nên chúng đáng có một ngày hẹn.

---

## 6. Bốn nhóm thiếu — có bằng chứng

Grep ở mục 1 ra **rỗng** cho cả bốn. Không phải "chưa hoàn thiện" — là **không có dòng nào**.

| Thiếu | Câu audit sẽ hỏi | Ghi chú |
|---|---|---|
| **AWS Backup** — không org policy (`BACKUP_POLICY`), không vault cross-account | *"khôi phục sau ransomware bằng gì"* | `organization` đã làm `SERVICE_CONTROL_POLICY` và `TAG_POLICY`; `BACKUP_POLICY` là cùng một cơ chế |
| **VPC Flow Logs** — có log Network Firewall vào S3, **không có** flow log | *"điều tra sự cố mạng bắt đầu từ dữ liệu nào"* | Chỗ bất ngờ nhất: thiết kế mạng rất công phu mà thiếu lớp dữ liệu cơ bản nhất |
| **IAM Access Analyzer** — không có analyzer cấp tổ chức | *"resource nào đang share ra ngoài tổ chức"* | Rẻ, và là một trong ít thứ CT không bật sẵn hộ bạn |
| **Inspector / Macie** — chỉ được **nhắc** trong một chú thích của `notify.tf` như lợi thế tương lai | *"quét lỗ hổng ở đâu"* | Đường báo động đã sẵn sàng nhận chúng — đó là phần khó, và nó đã xong |

Nhóm thiếu nhưng **hợp lý ở giai đoạn này**: SSM patch baseline, Service Quotas, auto-remediation (Config remediation / SSM Automation), break-glass thứ hai, session policy cho Deny liên account.

Một điểm công bằng cho bản DIY: dòng cuối bảng trên cho thấy phần **khó** của Inspector/Macie đã làm rồi. `notify.tf` cố ý **không** làm EventBridge fan-in cross-account, vì Security Hub đã gom sẵn — nên thêm Inspector hay Macie sau này chỉ là bật, không phải đi dây lại.

---

## 7. Ba việc ưu tiên

| # | Việc | Vì sao thứ tự này |
|---|---|---|
| **1** | Bật **một** Security Hub standard (`fsbp`), đo chi phí một tuần | Rẻ nhất, thu hẹp khoảng cách với CT nhiều nhất. Là **một dòng tfvars**, không phải code |
| **2** | **VPC Flow Logs** tập trung về log-archive | Không có nó thì mọi điều tra mạng bắt đầu từ chỗ không có dữ liệu |
| **3** | **AWS Backup cấp tổ chức** | Câu audit chắc chắn hỏi, và là thứ mất nhiều thời gian nhất để làm sau |

Việc thứ tư: chạy ba bộ test trong stage `Lint`. Quan trọng, nhưng nó **bảo vệ cái đã có** chứ không thêm năng lực mới — nên xếp sau.

---

## 8. Có nên chuyển sang Control Tower

**Ở quy mô và trạng thái hiện tại: không.**

Chuyển sang CT sẽ mất phần vận hành — cổng chặn đọc chiều nới/thắt, catalog có ticket, verify đọc AWS, 126 check — vốn là phần **mạnh nhất** của bản này. Và vẫn phải tự làm toàn bộ mạng. Đổi lại được một tập detective control mà mục 5 cho thấy có thể bật bằng một dòng tfvars.

**Lý do duy nhất tôi thấy đủ mạnh để chuyển là bus factor.** Nếu đội không giữ được **hai người** đọc hiểu `gate.py` và `loc.py`, thì CT không hơn về kỹ thuật nhưng hơn về khả năng thuê người và khả năng gọi AWS Support. Đó là một quyết định về tổ chức, không về hạ tầng.

Điều kiện chuyển theo thiết kế đã ghi ở [doc 21 mục 3](./21-Control-Tower-vs-DIY.md), và đánh giá này không đổi kết luận đó.

---

## 9. Sổ đánh giá

| Hạng mục | Điểm | Ghi chú |
|---|---|---|
| Nền tảng org/OU/SCP | **tốt** | 4 SCP gồm region deny; 15 check ở layer `organization` |
| Logging và bằng chứng | **tốt** | object lock ở cả `org-trail` và `config-detective`; bằng chứng nằm ngoài account bị kiểm |
| Identity | **tốt** | ranh giới pipeline/tay đúng chỗ: assignment tự động, nội dung permission set thì không |
| Network | **rất tốt** | vượt phạm vi CT hoàn toàn |
| Account vending | **tốt** | có hai stage *chờ* mà module pipeline không có |
| Detective control | **yếu** | 10 Config rule, 0 Security Hub standard, 6/6 GuardDuty feature tắt |
| Backup / DR | **không có** | |
| Dữ liệu điều tra mạng | **thiếu** | có firewall log, không có flow log |
| Đường tự động và cổng chặn | **rất tốt** | hơn CT |
| Kiểm chứng | **rất tốt** | verify đọc AWS; `kiem-log.sh` bắt cảnh báo lọt stage xanh |
| Auto-remediation | **không có** | phát hiện thuần |
| Khả năng người khác duy trì | **yếu** | bù một phần bằng doc 28–32; không bù hết được |

---

## Liên quan

- [Doc 21 — Control Tower vs DIY](./21-Control-Tower-vs-DIY.md) — so sánh **thiết kế guardrail**, và cách port ba loại control
- [Doc 23 — Lớp phát hiện](./23-Lop-Phat-Hien-GuardDuty-SecurityHub-Log-Archive.md) — cơ chế, tính năng, chi phí của lớp phát hiện
- [Doc 28 — Pipeline vận hành LZ](./28-Pipeline-Van-hanh-LZ-CodeCommit-CodePipeline.md) · [Doc 29](./29-Bo-loc-Kich-hoat-va-Cong-Chan.md) — phần "hơn CT"
- [Doc 31 — Bản đồ code](./31-Ban-do-Code-Landing-Zone.md) · [Doc 32 — Tham chiếu code](./32-Tham-chieu-Code-Tung-Layer.md)
- [Doc 11 — Tag policy và cost allocation](./11-Tag-Policy-va-Cost-Allocation.md) — vì sao tag policy còn report-only
