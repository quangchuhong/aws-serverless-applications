# Account Baseline

Thay cho **AFT** ở bản DIY. Chạy ở **management account**.

**Mặc định TẮT** (`enable = false`) — `terraform plan` ra 0 resource.

---

## Vì sao có layer này

Thêm một account vào LZ có **ba việc tay**, và **không việc nào báo lỗi khi quên**:

| Việc | Quên thì |
|---|---|
| `move-account` vào đúng OU | Account chỉ còn SCP ở root — mất `network_lock` và `prod_guard`, mà vẫn chạy bình thường |
| Xoá default VPC ở mọi region | Một Internet Gateway mở sẵn. `network_lock` chặn **tạo** IGW mới, nhưng không đụng tới cái AWS đã tạo lúc mở account |
| Thêm account ID vào `accounts_by_scope` | Không ai vào được account đó qua Identity Center, và người ta sẽ quay ra dùng root |

Ba sai lệch lặng lẽ — đúng thứ landing zone sinh ra để ngăn.

> **AFT là của Control Tower.** Bản DIY không có Control Tower nên không có AFT. Layer này làm phần việc đó.

---

## Ba việc, ba cách xử lý khác nhau

| Việc | Cách làm | Vì sao không làm cách khác |
|---|---|---|
| Xoá default VPC | **StackSet + Lambda**, `auto_deployment` | Terraform cần một provider alias cho mỗi account × region, mà provider **không sinh động được**. 6 account × 2 region = 12 alias viết tay, và account thứ 7 là sửa code |
| Đặt account vào OU | `aws_organizations_account` với `parent_id` | Tạo **thẳng** vào OU thì không còn bước chuyển, tức không còn chỗ để quên |
| Khai `accounts_by_scope` | **Output sinh sẵn khối HCL** | Layer này không sửa được tfvars của layer khác — mỗi layer một state, và tfvars nằm trong `.gitignore` |

Việc thứ ba là việc duy nhất không tự động hoá được. Nên thay vì cố, layer làm cho nó **không thể quên**: `unmapped_accounts` liệt kê account chưa ai khai pham vi.

---

## Xoá default VPC hoạt động thế nào

**Một** stack instance mỗi account, không phải mỗi account × region. Lambda bên trong tự quét các region trong `sweep_regions` — làm theo region thì số stack instance nhân lên mà không được gì.

```
StackSet (management)
  └─ auto_deployment ──► moi account trong baseline_target_ous
                            └─ Lambda quet sweep_regions
                                 └─ detach + delete IGW
                                 └─ delete subnet
                                 └─ delete VPC
```

`auto_deployment` là điểm mấu chốt: **account mới vào OU sẽ tự được dọn**, không phải chạy lại gì. Đó mới là cái đau thật — không phải sáu account hiện có, mà account thứ bảy.

### Hai SCP tương tác với nó

| SCP | Ảnh hưởng |
|---|---|
| `network_lock` | **Không cản.** Nó chỉ chặn `Create*` — `CreateInternetGateway`, `CreateNatGateway`, `AllocateAddress`. Không chặn `Delete*` |
| `region_lock` | **Có cản.** Chặn mọi hành động ngoài `allowed_regions`, kể cả `ec2:DeleteVpc` |

Nên `sweep_regions` phải khớp `allowed_regions`. Region ngoài danh sách sẽ ghi `SKIP` trong stack output.

> **`SKIP` ở region bị khoá không phải lỗ hổng.** Default VPC ở đó vô hại: không ai tạo được gì, và IGW nằm sẵn cũng không dùng được vì `ec2:RunInstances` bị `region_lock` từ chối trước. `SKIP` ở region **nằm trong** `allowed_regions` thì mới là vấn đề.

### Vì sao không dùng `cfnresponse`

Ví dụ của AWS cho Lambda inline dùng `import cfnresponse`, và module đó **có sẵn với một số runtime**. Với `python3.12` thì **không**:

```
Runtime.ImportModuleError: Unable to import module 'index':
No module named 'cfnresponse'
```

Hỏng ở đây là hỏng theo kiểu tệ nhất. Lambda chết ngay lúc **khởi tạo**, trước khi vào `try`, nên không nhánh nào gửi được phản hồi. CloudFormation ngồi chờ **hết một giờ** rồi mới bỏ cuộc — stack treo `CREATE_IN_PROGRESS`, và các account còn lại xếp hàng `PENDING` phía sau.

Hàm này tự gửi phản hồi bằng `urllib`, không phụ thuộc module nào ngoài thư viện chuẩn. Dài thêm 12 dòng, đổi lại không có gì để thiếu.

> **Bài học chung:** custom resource nào cũng phải trả lời được CloudFormation **kể cả khi chính nó hỏng**. Không trả lời được thì triệu chứng không phải "lỗi" mà là "treo một giờ" — khó chẩn đoán hơn hẳn.

### Buộc quét lại

Custom resource của CloudFormation **chỉ chạy lại khi thuộc tính đổi**. Thêm region vào `sweep_regions` mà không đổi `sweep_version` thì không có gì xảy ra.

```hcl
sweep_version = "2"   # doi de buoc quet lai
```

---

## Vending account — mặc định tắt

`create_accounts` để rỗng mặc định, và nên giữ vậy cho tới khi bạn chắc.

> **Gần như không hoàn tác được.** Account không xoá được, chỉ **đóng** được, và đóng xong phải chờ 90 ngày mới biến khỏi tổ chức. Email thì **duy nhất vĩnh viễn** ở phạm vi AWS toàn cầu — đóng account rồi cũng không dùng lại được email đó.

Hai lớp chặn:

- `close_accounts_on_destroy = false` (mặc định) — `terraform destroy` chỉ gỡ khỏi state, account vẫn chạy
- `prevent_destroy` trên resource — chặn destroy nhầm

Có `check` block cảnh báo nếu bật `close_accounts_on_destroy`, và một cái nữa nếu tạo account thẳng vào root thay vì OU.

Tạo tay bằng `create-account` cũng hoàn toàn được — chỉ mất thêm bước `move-account`.

---

## Chạy

```bash
cd landing-zone/account-baseline
cp terraform.tfvars.example terraform.tfvars

cd ../organization && terraform output ou_ids    # lay OU ID
cd ../account-baseline
```

Điền `baseline_target_ous`, `account_scopes`, đổi `enable = true`.

```bash
terraform init -backend-config=backend.hcl
terraform plan            # mong doi 2 to add: stack set + instance
terraform apply
```

---

## Kiểm chứng

```bash
# ~5 phut - StackSet da toi cac account chua
aws cloudformation list-stack-instances \
  --stack-set-name <project>-account-baseline --call-as SELF \
  --query 'Summaries[].[Account,Status]' --output table
```

**Xem nó xoá được gì** — đây là bước quan trọng nhất:

```bash
aws cloudformation describe-stacks --profile <account> --region <region> \
  --query "Stacks[?contains(StackName,'account-baseline')].Outputs[] | [?OutputKey=='SweepResult'].OutputValue" \
  --output text
```

> Dấu `[]` sau `Outputs` là bắt buộc. Không có nó thì JMESPath tạo một projection lồng và `--output text` in ra **rỗng** — trông y hệt như stack không có output nào, trong khi output vẫn ở đó.

| Kết quả | Nghĩa là |
|---|---|
| `ap-southeast-1/vpc-xxx` | Đã xoá |
| `khong co default VPC nao` | Không còn gì — đúng nếu đã dọn tay trước đó |
| `us-east-1/SKIP:ClientError` | Bị từ chối. Region ngoài `allowed_regions` thì bình thường |

**Kiểm độc lập** — đừng tin stack output, hỏi thẳng AWS. Lặp **mọi** region trong `sweep_regions`, không chỉ region đang mở terminal:

```bash
for p in <cac profile>; do
  printf '%-16s ' "$p"
  for r in <cac region trong sweep_regions>; do
    printf '%s=%s ' "$r" "$(aws ec2 describe-vpcs --region $r --profile $p \
      --filters Name=isDefault,Values=true --query 'length(Vpcs)' --output text)"
  done; echo
done
```

Tất cả phải ra `0`.

> **Vòng lặp một region là cái đã tạo ra lỗ hổng ngay từ đầu.** Lần dọn tay trước layer này chỉ chạy ở `ap-southeast-1`, và câu kiểm chứng cũng chỉ hỏi `ap-southeast-1` — nên nó xác nhận đúng cái giả định mà nó đáng ra phải kiểm. Layer này tìm thấy default VPC ở `us-east-1` tại **cả 5 account**. Chi tiết ở [doc 22 mục 6d](../../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md).

**Dán cấu hình sang layer khác:**

```bash
terraform output -raw paste_permission_sets
terraform output -raw paste_config_detective
terraform output unmapped_accounts
```

`unmapped_accounts` không rỗng = có account chưa ai khai phạm vi.

---

## Liên quan

| | |
|---|---|
| [`../organization`](../organization/) | OU ID, `allowed_regions`, hai SCP tương tác với sweep |
| [`../permission-sets`](../permission-sets/) | Nơi dán `accounts_by_scope` |
| [`../config-detective`](../config-detective/) | Nơi dán `excluded_accounts`, và khuôn StackSet layer này dùng lại |
| [doc 09](../../docs/09-Account-Vending-Tu-Dong.md) | Thiết kế account vending |
| [doc 22 mục 4](../../docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) | Nhật ký: default VPC được phát hiện thế nào |
