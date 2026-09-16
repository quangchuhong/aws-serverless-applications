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
| **Chi phí phần quản trị** | **$1.57 cả kỳ**, đo từ hoá đơn — xem mục 5.2 |

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

Và số liệu chi phí ở mục 5.2 lấy từ **export Cost Explorer**, hai chiều — theo account và theo dịch vụ. Không phải từ bảng giá AWS, không phải từ ước lượng.

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

### 2.4 Bảng đối chiếu từng hạng mục

Ba trục ở trên là kết luận. Bảng này là chỗ đọc ra kết luận đó, từng hạng mục một. Cột cuối nói **chênh lệch nghiêng về bên nào**, không phải "có/không".

| Hạng mục | AWS Control Tower | Bản này | Nghiêng về |
|---|---|---|---|
| Dựng nền lần đầu | Vài giờ, bấm nút | Nhiều ngày, viết code | **CT** |
| Cấu trúc OU | Theo khuôn của CT, có OU bắt buộc | Tự khai bằng YAML, hai tầng | **Bản này** |
| Guardrail phòng ngừa | Controls do AWS ship, bật/tắt theo OU | 4 SCP tự viết, gồm region deny | hoà |
| Guardrail phát hiện | Hàng trăm control ngày đầu | 10 Config rule, 0 Security Hub standard | **CT** |
| Sửa một guardrail | Trong khuôn CT cho phép; ngoài khuôn thì không | Sửa file, qua pipeline, có người duyệt | **Bản này** |
| CloudTrail tổ chức | ✓ | ✓ **+ object lock** ở log-archive | **Bản này** |
| Log archive tách account | ✓ | ✓ | hoà |
| Account vending | Account Factory / AFT | `vending-pipeline`, 7 stage trên 4 layer | hoà — xem ghi chú dưới |
| Baseline cho account mới | ✓ | ✓ qua StackSet | hoà |
| **Mạng** | **không làm gì** | TGW hub-spoke, VPC kiểm tra, egress/ingress tập trung, DNS, VPN đối tác | **Bản này, tuyệt đối** |
| Đọc plan và phân loại nới/thắt | ✗ | `gate.py`, 37 loại resource có luật chiều | **Bản này** |
| Nới quyền buộc có ticket + hạn | ✗ | `ops-loosen.yaml`, vòng bốn nhịp | **Bản này** |
| Cổng duyệt người giữa plan và apply | ✗ | `approve_stages` | **Bản này** |
| Kiểm chứng bằng cách đọc AWS | ✗ — dashboard đọc Config | 7 script verify, không đụng state | **Bản này** |
| Drift | LZ drift, phạm vi hẹp hơn | Mỗi pipeline một job, không có nhánh apply | **Bản này** |
| Bắt cảnh báo lọt qua stage xanh | ✗ | `kiem-log.sh` | **Bản này** |
| Kiến thức tổ chức mã hoá trong code | ✗ | 126 `check` | **Bản này** |
| Region / partition không được CT hỗ trợ | ✗ | chạy được | **Bản này** |
| Trạng thái "landing zone needs update" chặn thay đổi | có | không tồn tại | **Bản này** |
| Đường nâng cấp được quản lý | AWS ship control mới | tự đọc Control Catalog rồi port tay | **CT** |
| AWS Support debug hộ | ✓ | ✗ | **CT** |
| Thuê người biết sẵn | ✓ | ✗ | **CT** |

**Ghi chú về dòng account vending** — nó ghi "hoà" chứ không ghi "CT", và đó không phải nhân nhượng: nếu muốn vend account bằng Terraform thì CT đưa bạn tới **AFT**, mà AFT là **một bộ pipeline bạn phải tự vận hành** trong một account riêng của nó — CodePipeline, CodeBuild, Step Functions, DynamoDB. Nghĩa là gánh nặng vận hành không biến mất khi dùng CT; nó chỉ đổi tên.

### 2.5 Chi phí — hai bên trả cho cái gì

Điểm khởi đầu phải nói rõ, vì đây là chỗ hay bị nói sai theo cả hai chiều:

> **Bản thân Control Tower không tính phí, và bản này cũng vậy.** Cả hai đều trả tiền cho **những dịch vụ bên dưới được bật lên**. Nên câu hỏi đúng không phải "cái nào rẻ hơn", mà là **"ai quyết định bật cái gì"**.

Và đó chính là chỗ chênh lệch:

| | Control Tower | Bản này |
|---|---|---|
| Ai chọn phạm vi ghi nhận của Config | CT đặt baseline, ghi rộng trên mọi region được quản trị | **Khai trong code**: 10 org rule, 2 region |
| Thu hẹp phạm vi đó | Là một thao tác trên landing zone, trong khuôn CT cho phép | Sửa một dòng, qua pipeline |
| Biết một tính năng có đang tốn tiền không | Đọc bảng giá rồi suy ra | **Đọc hoá đơn** — và nó khớp với `terraform output` |
| Tắt cả một lớp để tiết kiệm | Không có khái niệm đó — baseline luôn chạy ở mọi account được quản trị | `terraform destroy` một layer, dựng lại khi cần |

**Bốn ưu thế chi phí của bản này, mỗi cái kiểm lại được:**

1. **Mọi công tắc đều tường minh, và hoá đơn xác nhận được.** Dòng `Security Hub $0.00` ở mục 5.2 là bằng chứng độc lập cho `standards = []`. Một tính năng đang bật thì **không thể** có hoá đơn bằng không. Ở CT bạn không có phép đối chiếu này, vì baseline không do bạn khai.

2. **Phạm vi Config do mình chọn — và Config là dòng lớn nhất.** Trong $1,57 đo được, Config chiếm **$1,04**, tức hai phần ba. Config tính theo số configuration item ghi nhận và số lần đánh giá rule, nên nó nhân theo **account × region × mức độ thay đổi resource**. Đây là đòn bẩy chi phí lớn nhất của bất kỳ landing zone nào, và ở bản này nó là một con số trong code.

3. **Tắt được cả một lớp mà không phá nền tảng.** Network Firewall ra **$0,0988** vì lớp mạng được dựng, kiểm chứng một đến hai giờ, rồi xoá. Không phải vì nó rẻ — mà vì *xoá và dựng lại được*. CT không có tương đương: baseline của nó chạy ở mọi account được quản trị, không có cách "tạm đỗ" mà vẫn giữ landing zone.

4. **Không có chi phí ẩn của chu kỳ cập nhật.** CT sinh ra trạng thái *landing zone needs update*, và trong lúc đó một số thao tác bị chặn cho tới khi có người chạy cập nhật trên toàn tổ chức. Đó là chi phí bằng **thời gian kỹ sư** chứ không nằm trên hoá đơn — nhưng nó là chi phí thật, và nó lặp lại.

**Chỗ CT rẻ hơn, và nó không nhỏ:** bạn không phải trả cho việc *dựng* sáu pipeline, `gate.py`, `loc.py`, 22 script và 126 `check`. Chi phí đó đã trả bằng thời gian, và nó tiếp tục trả bằng bus factor ở mục 4. Nếu tính tổng chi phí sở hữu trong ba năm mà quy thời gian kỹ sư ra tiền, kết luận có thể đảo chiều — và đó là một quyết định tổ chức, không phải một phép so hoá đơn.

**Một cảnh báo về quy mô:** $1,57 là số của **năm account, trong một kỳ ngắn hơn kỳ dựng**. Ở 50 account, con số tuyệt đối tăng nhiều lần — nhưng **thứ tự trong bảng không đổi**: Config vẫn là dòng lớn nhất, và phần quản trị vẫn nhỏ hơn hạ tầng mạng chạy thường trú (~$1.020/tháng ở 2 AZ / 5 spoke) một bậc rõ rệt.

> Kiểm lại hai con số này bằng chính công cụ đã sinh ra chúng: xuất Cost Explorer theo **account** và theo **dịch vụ**, lọc ra account quản trị (ở đó có hệ thống chạy từ trước nền tảng này), rồi đối chiếu với `terraform output` của `config-detective`. Hai nguồn không liên quan phải nói cùng một điều — nếu không, một trong hai sai.

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

### 5.1 Bốn công tắc

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

### 5.2 Hoá đơn xác nhận điều đó, và nó rẻ hơn dự đoán

Export Cost Explorer cho **năm account của LZ** (loại account quản trị ra, vì ở đó có một hệ thống ứng dụng chạy từ trước nền tảng này):

| Dịch vụ | Cả kỳ | Đọc ra điều gì |
|---|---|---|
| Config | **$1.04** | dòng lớn nhất của cả phần quản trị |
| CodeBuild + CodePipeline | **$0.69** | sáu pipeline cộng job drift, hàng chục lần chạy |
| GuardDuty | **$0.27** | bật ở 14 account thành viên |
| S3 | **$0.17** | nhật ký, state, snapshot |
| Network Firewall | **$0.0988** | xem cảnh báo dưới |
| CloudTrail | **$0.00** | trail cấp tổ chức không tính phí |
| **Security Hub** | **$0.00** | ← **hoá đơn xác nhận `standards = []`** |
| SNS · SQS · CodeCommit | **$0.00** | trong hạn miễn phí ở quy mô này |
| **Cộng, năm account** | **$1.57** | |

Dòng `Security Hub $0.00` là một **bằng chứng độc lập** cho mục 5.1: nếu có standard nào đang bật thì nó không thể bằng không. Trạng thái đọc từ `terraform output` và trạng thái đọc từ hoá đơn khớp nhau — hai nguồn không liên quan cùng nói một điều.

> **`$0.0988` KHÔNG có nghĩa là Network Firewall rẻ.** Nó có nghĩa là lớp mạng **chưa bao giờ được để chạy**: dựng lên, kiểm chứng một đến hai giờ, rồi xoá. Điểm kiểm tra tính tiền theo **giờ**, nên vài giờ ra vài xu.
>
> Đó là một điểm mạnh thật — *xoá và dựng lại được* nên kiểm chứng gần như không tốn gì. Nhưng nó không trả lời câu "chạy thường trú tốn bao nhiêu". Câu đó là **phép tính**, không phải phép đo:
>
> `(số AZ × $0.44/giờ) + (số spoke × $0.05/giờ) + $0.15/giờ`
>
> 2 AZ / 5 spoke ≈ **$1.020/tháng**, trong đó ~$577 là firewall endpoint. **Thêm một AZ đắt hơn thêm mười lăm spoke** — tường lửa nhân theo AZ, không theo lưu lượng hay số spoke.

**Một lưu ý về phạm vi số liệu:** export kết thúc ở hết tháng 8, mà LZ dựng từ **cuối tháng 8 tới giữa tháng 9**. Nên `$1.57` là **cận dưới** — nó chỉ bắt được mấy ngày đầu. Xuất thêm tháng 9 thì con số tăng, nhưng vẫn ở thang vài đô: không dịch vụ nào trong bảng có đơn giá đủ lớn để đổi bậc.

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

> **Chi phí thực hiện của ba việc đầu — đo bằng code, ở mục 7.2.** Đừng xếp sprint từ bảng này: ba việc nhìn ngang nhau ở đây, mà công sức thật lệch nhau 3 lần về số layer phải chạm.

Một điểm công bằng cho bản DIY: dòng cuối bảng trên cho thấy phần **khó** của Inspector/Macie đã làm rồi. `notify.tf` cố ý **không** làm EventBridge fan-in cross-account, vì Security Hub đã gom sẵn — nên thêm Inspector hay Macie sau này chỉ là bật, không phải đi dây lại.

---

## 7. Ba việc ưu tiên

### 7.1 Xếp theo giá trị

| # | Việc | Vì sao |
|---|---|---|
| **1** | Bật **một** Security Hub standard (`fsbp`), đo chi phí một tuần | Rẻ nhất, thu hẹp khoảng cách với CT nhiều nhất |
| **2** | **VPC Flow Logs** tập trung về log-archive | Không có nó thì mọi điều tra mạng bắt đầu từ chỗ không có dữ liệu |
| **3** | **AWS Backup cấp tổ chức** | Câu audit chắc chắn hỏi, và là thứ mất nhiều thời gian nhất để làm sau |

Việc thứ tư: chạy ba bộ test trong stage `Lint`. Quan trọng, nhưng nó **bảo vệ cái đã có** chứ không thêm năng lực mới — nên xếp sau.

### 7.2 Chi phí thực hiện, đo bằng code chứ không bằng cảm giác

Ba việc trên nhìn ngang nhau. Đọc code thì không, và nó lệch **cả hai chiều** so với phỏng đoán ban đầu.

#### Việc 1 — Security Hub `fsbp`: không một dòng code

```hcl
# config-detective/terraform.tfvars
security_hub_standards = ["fsbp"]
```

**Nhưng không phải "push là xong".** `aws_securityhub_standards_subscription.this` nằm **ngoài `-target`** của stage `cloudops-config-rules` (stage đó chỉ được chạm `aws_config_organization_managed_rule`). Nên phải apply tay:

```bash
cd landing-zone/config-detective
terraform apply -target=aws_securityhub_standards_subscription.this
cd ../vending-pipeline && ./push-tfvars.sh   # de job drift khong bao lech moi dem
```

Dòng thứ hai không bỏ được: job drift chạy `plan` **không** `-target`, nên tfvars ở S3 lệch với local sẽ thành một dòng drift mỗi đêm.

**Cái đắt không phải công sức mà là hoá đơn.** FSBP ~200 control × 14 account × 2 region, tính theo số lần kiểm. Đó là lý do `check.security_hub_costs_money` tồn tại. Bật một standard, một region trước, đo một tuần.

#### Việc 2 — Flow Logs: **không dễ**, và rào cản là provider

```
network/versions.tf          → 1 provider, KHÔNG alias   ← không với tới log-archive
config-detective/versions.tf → alias "security", alias "log_archive"
```

Gom flow log về log-archive cần **ba** chỗ:

| Layer | Việc | Vì sao phải ở đây |
|---|---|---|
| `config-detective` | bucket ở log-archive + bucket policy cho `delivery.logs.amazonaws.com` | layer duy nhất có provider alias `log_archive` |
| `network` | `aws_flow_log` cho VPC hub, nhận ARN bucket qua **biến** | VPC hub khai ở đây |
| `account-baseline` | VPC spoke ở account thành viên sinh từ **CloudFormation StackSet** → sửa template, không phải Terraform | StackSet là thứ rải xuống account thành viên |

Và nó tạo một **cạnh phụ thuộc liên layer mới**. Mục 6 của [doc 31](./31-Ban-do-Code-Landing-Zone.md) ghi rằng cả hạ tầng hiện chỉ có **hai** cạnh như vậy, cố ý — *mỗi cạnh là một layer có thể làm layer khác chết*. Đây sẽ là cạnh thứ ba, nên nó cần một quyết định chứ không chỉ một lần code.

Chi phí vận hành cũng không nhỏ: flow log tính theo GB thu nhận **và** GB lưu trữ, và nó là một trong những dòng hoá đơn lớn ở quy mô.

#### Việc 3 — AWS Backup: **dễ hơn phỏng đoán**, và chỗ tôi suýt nói sai

Phỏng đoán ban đầu: rào cản lớn nhất là phải bật `BACKUP_POLICY` ở cấp tổ chức. Đọc code thì nó **đã bật sẵn**:

```hcl
# organization/organization.tf:16
enabled_policy_types = [
  "SERVICE_CONTROL_POLICY",
  "TAG_POLICY",
  "BACKUP_POLICY",      # <- da co
]
```

Nên chia làm hai mức, và mức đầu thật sự dễ:

| Mức | Việc | Công sức |
|---|---|---|
| **Tối thiểu** | một file mới trong `organization`, đúng khuôn `tag-policy.tf`: `aws_organizations_policy` type `BACKUP_POLICY` + attachment, chọn resource theo tag, ghi vào vault mặc định của từng account | ~60 dòng, **một** layer |
| **Đạt chuẩn audit** | thêm một vault **bất biến ở log-archive** + vault policy cho phép sao lưu chéo từ tổ chức | thêm một layer (`config-detective` có sẵn alias) |

Mức tối thiểu chạm layer `organization` — **sec sở hữu**, nên cần họ duyệt, và `gate.py` sẽ coi việc thêm một policy type mới là thay đổi cần đọc.

### 7.3 Thứ tự sau khi đo

| | Việc | Công sức | Số layer chạm |
|---|---|---|---|
| 1 | Security Hub `fsbp` | 1 dòng tfvars + 1 lệnh apply | 1 |
| 2 | AWS Backup **tối thiểu** | ~60 dòng, 1 file mới | 1 *(sec duyệt)* |
| 3 | Flow Logs | 3 layer + 1 cạnh phụ thuộc mới | 3 |
| 4 | Backup **vault cross-account** | thêm vault + policy | 2 |

**Thứ tự này đảo việc 2 và 3 so với 7.1**, và lý do là thứ chỉ thấy được sau khi đọc code: Backup tối thiểu rẻ hơn Flow Logs nhiều, dù giá trị audit cao hơn. Xếp theo giá trị thì Flow Logs trước; xếp theo *giá trị chia cho công sức* thì Backup trước.

Cả hai thứ tự đều đúng — chỉ là trả lời hai câu hỏi khác nhau. Dùng 7.1 khi trình bày với người ra quyết định, dùng 7.3 khi lên sprint.

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
