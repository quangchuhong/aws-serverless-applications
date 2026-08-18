# Đồng bộ user/group từ AD on-premise sang AWS IAM Identity Center

Ví dụ 08: Nối identity từ **Active Directory on-premise** vào **AWS IAM Identity Center**, tiếp nối [06 – Landing Zone](./06-Aws-Landing-Zone.md) (mục 10, permission sets) và [07 – Centralized DNS](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md) (mục 10.2, Entra Connect).

> **Không có AD on-premise?** Bài này vẫn đáng đọc phần mục 1 (AD OU ≠ AWS OU), nhưng phần đồng bộ thì không cần. Môi trường thuần AWS dùng Identity Center directory và Terraform làm chủ user/group — xem [19 – Permission set cho LZ](./19-Permission-Set-cho-Landing-Zone.md).
>
> **Khác biệt cốt lõi giữa hai bài:** ở đây SCIM làm chủ nên Terraform chỉ được **đọc** group (`data "aws_identitystore_group"`). Không có AD thì Terraform **làm chủ** (`resource`). Đừng trộn hai kiểu.

---

## 1. Trước hết: "OU" của AD và "OU" của AWS là hai thứ khác nhau

Đây là hiểu nhầm phổ biến nhất, và nó làm cả thiết kế đi sai hướng nếu không gỡ sớm:

| Khái niệm | Chứa cái gì | Dùng để làm gì | Đồng bộ được không |
|---|---|---|---|
| **AD OU** (`OU=Staff,DC=corp,DC=acme,DC=local`) | User, computer, group | Áp GPO, phân quyền quản trị AD, phạm vi delegate | — |
| **AWS Organizations OU** (`Workloads/Prod`) | **AWS account** | Áp SCP, gom account theo môi trường | ❌ Không |
| **Identity Center group** (`AWS-app-prod-ReadOnly`) | User đã đồng bộ | Gán Permission Set vào account | ✅ Có |

Nói thẳng: **không có cơ chế nào đồng bộ AD OU sang AWS Organizations OU**, và cũng không nên có. AWS Organizations OU chứa *account*, còn AD OU chứa *người và máy*. Hai cây này giải quyết hai bài toán khác nhau.

Cái thực sự đồng bộ được là **user và group**. Còn AD OU vẫn có vai trò, nhưng là vai trò khác:

- **Phạm vi lọc**: Entra Connect chọn OU nào được sync lên cloud (mục 4.1).
- **Nguồn cho dynamic group**: thuộc tính của user trong OU (`department`, `physicalDeliveryOfficeName`) dùng để tự động gom nhóm (mục 4.5).
- **Nguồn cho ABAC**: thuộc tính user trở thành session tag trong AWS (mục 7).

---

## 2. Mô hình ánh xạ đúng

Chuỗi liên kết từ người dùng tới quyền trên AWS:

```text
   AD on-premise                Entra ID              IAM Identity Center        AWS
┌──────────────────┐      ┌──────────────────┐     ┌────────────────────┐   ┌──────────┐
│ OU=Staff         │      │                  │     │                    │   │          │
│  └ user: nguyenva│─────►│ user             │────►│ user               │   │          │
│                  │ Entra│ nguyenva@acme.com│SCIM │ nguyenva@acme.com  │   │          │
│ OU=Groups/AWS    │Connect                  │     │                    │   │          │
│  └ AWS-app-prod- │─────►│ group            │────►│ group              │   │          │
│    Developer     │      │ AWS-app-prod-    │     │ AWS-app-prod-      │   │          │
│                  │      │ Developer        │     │ Developer          │   │          │
└──────────────────┘      └──────────────────┘     └─────────┬──────────┘   │          │
                                    │ SAML                    │              │          │
                                    │ (đăng nhập)             │ Account      │          │
                                    ▼                         │ Assignment   │          │
                            login.microsoftonline.com         ▼              ▼          │
                                                    Permission Set ────► account        │
                                                    DeveloperAccess      app-prod       │
                                                                        (OU: Workloads/ │
                                                                            Prod)       │
                                                                       └────────────────┘
```

Đọc theo chiều ngang: **một AD group = một (account × permission set)**.

Group `AWS-app-prod-Developer` nghĩa là: ai ở trong group này thì có `DeveloperAccess` trên account `app-prod`. Bỏ người ra khỏi group AD → mất quyền. Toàn bộ vòng đời quyền hạn quay về đúng chỗ mà bộ phận IT đã quen: **quản lý group trong AD**.

Hai luồng riêng biệt, đừng lẫn:

- **SCIM** (provisioning): đẩy *danh sách* user/group vào Identity Center. Chạy nền, định kỳ.
- **SAML** (authentication): xác thực lúc user bấm đăng nhập. Chạy real-time.

Cần cả hai. Thiếu SCIM thì không có gì để gán quyền; thiếu SAML thì không đăng nhập được.

---

## 3. Chọn cách đồng bộ

Ba đường, chọn theo hiện trạng:

| Cách | Nguồn identity | Khi nào chọn | Hạn chế |
|---|---|---|---|
| **A. Entra ID làm IdP** (khuyến nghị) | AD → Entra Connect → Entra ID → SCIM | Đã có M365/Entra (trường hợp của bạn) | Không sync nested group |
| **B. AD Connector / Managed AD** | Identity Center đọc thẳng AD | Không có Entra, không muốn đưa identity lên cloud | Phụ thuộc đường DX/VPN; MFA hạn chế hơn |
| **C. IdP bên thứ ba** | Okta / Ping / JumpCloud | Đã đầu tư IdP đó rồi | Thêm một hệ thống phải vận hành |

Vì [doc 07](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md) đã dựng M365 + Entra Connect, **đường A gần như miễn phí về công sức** – bạn tái sử dụng đúng hạ tầng sync đang chạy cho Office 365. Bài này đi theo đường A, mục 5 nói về đường B cho trường hợp không dùng Entra.

> Cảnh báo trước khi bắt đầu: **đổi identity source của Identity Center sẽ xoá user/group hiện có và các assignment gắn với chúng.** Nếu đang chạy Identity Center directory với user tạo tay và muốn chuyển sang Entra, hãy export assignment ra trước, và làm việc này càng sớm càng tốt trong vòng đời LZ.

---

## 4. Đường A – AD → Entra Connect → Entra ID → SCIM → Identity Center

### 4.1. Bước 0: chọn OU nào được sync

Đây chính là chỗ **AD OU có vai trò thật**. Trong Entra Connect wizard: *Configure → Customize synchronization options → Domain and OU filtering*.

Nguyên tắc: **chỉ sync những gì cần**. Đừng bật cả domain.

| OU | Sync? | Lý do |
|---|---|---|
| `OU=Staff` | ✅ | Nhân viên thật, cần đăng nhập M365 + AWS |
| `OU=Contractors` | ✅ | Nhưng nên tách group riêng, session ngắn hơn |
| `OU=Groups/AWS` | ✅ | Chứa các group `AWS-*` để phân quyền |
| `OU=ServiceAccounts` | ❌ | Service account dùng IAM role, không cần lên cloud |
| `OU=Computers` | ❌ | Trừ khi làm Hybrid Entra Join |
| `CN=Builtin`, `OU=Disabled` | ❌ | Không có lý do gì để lên cloud |

Kiểm tra cấu hình hiện tại và chạy sync thủ công:

```powershell
# Xem connector va scope dang cau hinh
Get-ADSyncConnector | Select-Object Name, Type

# Trang thai scheduler (mac dinh 30 phut/lan)
Get-ADSyncScheduler

# Chay dong bo ngay (Delta cho thay doi, Initial cho full)
Start-ADSyncSyncCycle -PolicyType Delta

# Kiem tra user da len chua
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUser -Filter "userPrincipalName eq 'nguyenva@acme.com'" |
    Select-Object DisplayName, UserPrincipalName, OnPremisesSyncEnabled
```

`OnPremisesSyncEnabled = True` xác nhận user này đến từ AD chứ không phải tạo tay trên cloud.

> Nhắc lại từ [doc 07 mục 10.2](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md): UPN phải là suffix routable (`@acme.com`), không phải `@corp.acme.local`. Nếu chưa xử lý, làm xong bước đó rồi hãy đi tiếp — username trên AWS lấy từ UPN.

### 4.2. Bước 1: chuẩn hoá tên group trong AD

Toàn bộ phần tự động hoá ở mục 6 dựa vào naming convention. Đặt quy ước **trước khi** tạo group thứ nhất:

```text
AWS-<account_key>-<PermissionSetName>

AWS-app-dev-Developer
AWS-app-dev-ReadOnly
AWS-app-prod-ReadOnly
AWS-app-prod-Developer
AWS-network-Admin
AWS-security-SecurityAudit
AWS-all-Admin            # platform team, mọi account
```

Tạo group bằng PowerShell cho đồng nhất:

```powershell
$OuPath = "OU=AWS,OU=Groups,DC=corp,DC=acme,DC=local"

$Groups = @(
    @{ Name = "AWS-app-dev-Developer";      Desc = "DeveloperAccess tren account app-dev" }
    @{ Name = "AWS-app-dev-ReadOnly";       Desc = "ReadOnlyAccess tren account app-dev" }
    @{ Name = "AWS-app-prod-Developer";     Desc = "DeveloperAccess tren account app-prod" }
    @{ Name = "AWS-app-prod-ReadOnly";      Desc = "ReadOnlyAccess tren account app-prod" }
    @{ Name = "AWS-network-Admin";          Desc = "AdministratorAccess tren account network" }
    @{ Name = "AWS-security-SecurityAudit"; Desc = "SecurityAudit tren account security" }
)

foreach ($g in $Groups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name        $g.Name `
                    -GroupScope  Universal `
                    -GroupCategory Security `
                    -Path        $OuPath `
                    -Description $g.Desc
        Write-Host "Created: $($g.Name)"
    }
}

# Them user vao group
Add-ADGroupMember -Identity "AWS-app-dev-Developer" -Members nguyenva, tranthib
```

Vì sao đặt tên chặt chẽ đến vậy: mục 6 sẽ sinh toàn bộ `aws_ssoadmin_account_assignment` từ chính chuỗi tên này. Sai một ký tự = Terraform không tìm thấy group và apply fail (điều này tốt — fail sớm còn hơn cấp nhầm quyền).

### 4.3. Bước 2: kết nối Entra ID với Identity Center

Phần này làm qua console vì có bước trao đổi metadata thủ công:

**Phía AWS** — IAM Identity Center console → *Settings → Identity source → Change to External identity provider*:
1. Tải file **IdP SAML metadata** từ Entra lên (lấy ở bước dưới).
2. Ghi lại **SCIM endpoint** và **Access token** mà AWS sinh ra. Token này chỉ hiện **một lần** — cất vào Secrets Manager ngay.
3. Bật *Automatic provisioning*.

**Phía Entra** — Entra admin center → *Enterprise applications → New application* → tìm **"AWS IAM Identity Center"** trong gallery:
1. Tab *Single sign-on → SAML*: tải metadata của AWS lên, rồi tải metadata của Entra xuống để đưa ngược sang AWS.
2. Tab *Provisioning → Automatic*: điền SCIM endpoint + token ở trên, bấm **Test Connection**.
3. Tab *Users and groups*: gán các group `AWS-*` vào app này.

Bước 3 là chỗ hay bị bỏ sót: **Entra chỉ provision những group đã được gán vào enterprise app.** Group tồn tại trong Entra nhưng không gán vào app thì không bao giờ xuất hiện ở Identity Center.

Gán hàng loạt bằng Graph PowerShell cho đỡ click:

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All","Group.Read.All"

$sp = Get-MgServicePrincipal -Filter "displayName eq 'AWS IAM Identity Center'"
if (-not $sp) { throw "Khong tim thay enterprise app. Tao app tu gallery truoc." }

$groups = Get-MgGroup -Filter "startswith(displayName,'AWS-')" -All

foreach ($g in $groups) {
    $existing = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $sp.Id -All |
                Where-Object { $_.PrincipalId -eq $g.Id }

    if ($existing) {
        Write-Host "Da gan roi: $($g.DisplayName)"
        continue
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $sp.Id `
        -PrincipalId        $g.Id `
        -ResourceId         $sp.Id `
        -AppRoleId          ([Guid]::Empty)   # Guid rong = "Default Access"

    Write-Host "Da gan: $($g.DisplayName)"
}
```

### 4.4. Bước 3: attribute mapping

Trong tab *Provisioning → Mappings*, những attribute quan trọng:

| Entra attribute | SCIM attribute | Ghi chú |
|---|---|---|
| `userPrincipalName` | `userName` | Username hiển thị trên AWS |
| `mail` | `emails[type eq "work"].value` | Bắt buộc |
| `displayName` | `displayName` | |
| `objectId` | `externalId` | Khoá liên kết — **đừng đổi** |
| `department` | `urn:…:enterprise:2.0:User:department` | Cần cho ABAC ở mục 7 |
| `employeeId` | `urn:…:enterprise:2.0:User:employeeNumber` | Hữu ích khi audit |
| `accountEnabled` | `active` | Disable AD → tự khoá trên AWS |

Dòng `accountEnabled → active` chính là cơ chế **offboarding tự động**: disable tài khoản trong AD → Entra Connect sync trạng thái → SCIM đẩy `active = false` → user mất quyền vào AWS mà không ai phải nhớ làm gì thêm.

Chu kỳ provisioning của Entra khoảng **40 phút**. Khi test dùng **Provision on demand** để không phải chờ.

### 4.5. Tuỳ chọn: dynamic group thay cho quản lý thành viên thủ công

Nếu muốn "ai ở OU/department nào thì tự có quyền tương ứng", dùng **dynamic group** trong Entra (cần license Entra ID P1) với rule dựa trên thuộc tính đã sync từ AD:

```text
# Group: AWS-app-dev-Developer
(user.department -eq "Engineering") and (user.accountEnabled -eq true)

# Group: AWS-security-SecurityAudit
(user.department -eq "Information Security")

# Loại contractor ra khỏi quyền prod
(user.department -eq "Engineering") and (user.employeeType -ne "Contractor")
```

Đây là cách gần nhất với ý tưởng "map theo OU": bạn không map OU trực tiếp, nhưng OU trong AD thường đi kèm `department`/`extensionAttribute`, và rule ở trên biến thuộc tính đó thành quyền trên AWS. Muốn map thẳng theo OU thì dùng `user.onPremisesDistinguishedName`:

```text
user.onPremisesDistinguishedName -contains "OU=Engineering,OU=Staff,DC=corp,DC=acme,DC=local"
```

Cách này chạy được nhưng giòn — cứ tái cấu trúc cây OU là quyền AWS đổi theo mà không ai để ý. Ưu tiên `department`/`employeeType`.

---

## 5. Đường B – dùng AD trực tiếp làm identity source

Khi không có Entra (hoặc chính sách không cho đưa identity lên cloud), Identity Center kết nối thẳng vào AD qua **AWS Managed Microsoft AD** (đã dựng ở [doc 07 mục 9](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md)) hoặc **AD Connector**.

```hcl
# Identity Center dùng Managed AD (đã có trust hai chiều với on-prem) làm nguồn.
# Việc "kết nối directory" làm ở console: Identity Center → Settings →
# Identity source → Change to Active Directory → chọn directory.
# Terraform không quản lý bước này; sau đó tra cứu group bằng data source:

data "aws_identitystore_group" "developers" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "AWS-app-dev-Developer"
    }
  }
}
```

Khác biệt cần biết so với đường A:

| | Đường A (Entra + SCIM) | Đường B (AD trực tiếp) |
|---|---|---|
| Đăng nhập khi đứt Direct Connect | Vẫn được (auth ở Entra) | **Mất**, trừ khi có trust + Managed AD chạy độc lập |
| MFA | Toàn bộ tính năng Entra Conditional Access | MFA của Identity Center (RADIUS hoặc built-in) |
| Nested group | Không hỗ trợ | Hỗ trợ (đọc thẳng AD) |
| Độ trễ khi đổi group | ~40 phút (chu kỳ SCIM) | Gần như tức thì |
| Chi phí thêm | $0 (dùng lại Entra Connect) | ~$88+/tháng cho Managed AD |

Đường B có một ưu điểm thật: **nested group chạy được**, mà đây lại là hạn chế đau đầu nhất của đường A (mục 9).

---

## 6. Terraform – sinh assignment từ naming convention

Đây là phần đáng giá nhất của cả bài: chỉ khai báo danh sách grant, Terraform tự tra group và tạo assignment.

### 6.1. 4-identity-center/assignments.tf

```hcl
data "aws_ssoadmin_instances" "this" {}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
}

variable "account_ids" {
  description = "Output tu 1-organization"
  type        = map(string)
  # {
  #   log_archive = "222222222222"
  #   security    = "333333333333"
  #   network     = "444444444444"
  #   app_dev     = "555555555555"
  #   app_prod    = "666666666666"
  # }
}

########################
# Khai báo grant – nguồn sự thật duy nhất
########################

locals {
  # account_key phải khớp key trong var.account_ids
  # permission_set phải khớp tên permission set ở doc 06 mục 10
  # (hoặc bộ 17 set đầy đủ ở doc 19 — lz-network-admin, lz-app-admin...)
  grants = [
    { account_key = "app_dev",  permission_set = "DeveloperAccess"    },
    { account_key = "app_dev",  permission_set = "ReadOnlyAccess"     },
    { account_key = "app_prod", permission_set = "ReadOnlyAccess"     },
    { account_key = "app_prod", permission_set = "DeveloperAccess"    },
    { account_key = "network",  permission_set = "AdministratorAccess"},
    { account_key = "security", permission_set = "SecurityAudit"      },
  ]

  # Sinh tên group AD tương ứng: AWS-app-dev-Developer
  # (bỏ hậu tố "Access" cho tên group gọn hơn)
  grants_map = {
    for g in local.grants :
    "${g.account_key}-${g.permission_set}" => merge(g, {
      group_name = format(
        "AWS-%s-%s",
        replace(g.account_key, "_", "-"),
        replace(g.permission_set, "Access", "")
      )
    })
  }
}

########################
# Tra cứu group đã được SCIM đẩy sang
# Dùng DATA SOURCE, không phải resource – SCIM là chủ sở hữu các group này
########################

data "aws_identitystore_group" "grants" {
  for_each          = local.grants_map
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.value.group_name
    }
  }
}

########################
# Assignment
########################

resource "aws_ssoadmin_account_assignment" "grants" {
  for_each = local.grants_map

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.all[each.value.permission_set].arn
  principal_id       = data.aws_identitystore_group.grants[each.key].group_id
  principal_type     = "GROUP"
  target_id          = var.account_ids[each.value.account_key]
  target_type        = "AWS_ACCOUNT"
}

########################
# Platform team: admin ở MỌI account, gọn trong một group AD
########################

data "aws_identitystore_group" "platform_admin" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = "AWS-all-Admin"
    }
  }
}

resource "aws_ssoadmin_account_assignment" "platform_admin" {
  for_each = var.account_ids

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.all["AdministratorAccess"].arn
  principal_id       = data.aws_identitystore_group.platform_admin.group_id
  principal_type     = "GROUP"
  target_id          = each.value
  target_type        = "AWS_ACCOUNT"
}

output "assignment_summary" {
  value = {
    for k, v in local.grants_map :
    k => "${v.group_name} -> ${v.permission_set} @ ${var.account_ids[v.account_key]}"
  }
}
```

### 6.2. Permission sets khai báo bằng for_each

Gọn hơn cách viết từng resource ở doc 06:

```hcl
locals {
  permission_sets = {
    AdministratorAccess = {
      description      = "Full admin - chi platform team"
      session_duration = "PT4H"
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
    }
    DeveloperAccess = {
      description      = "Deploy workload, khong dung IAM/Organizations"
      session_duration = "PT8H"
      managed_policies = ["arn:aws:iam::aws:policy/PowerUserAccess"]
    }
    ReadOnlyAccess = {
      description      = "Auditor / on-call"
      session_duration = "PT8H"
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
    }
    SecurityAudit = {
      description      = "Security team"
      session_duration = "PT8H"
      managed_policies = [
        "arn:aws:iam::aws:policy/SecurityAudit",
        "arn:aws:iam::aws:policy/AWSSecurityHubReadOnlyAccess",
      ]
    }
  }

  # Làm phẳng để attach policy bằng một for_each
  ps_policies = merge([
    for ps_name, ps in local.permission_sets : {
      for arn in ps.managed_policies :
      "${ps_name}|${basename(arn)}" => { ps = ps_name, arn = arn }
    }
  ]...)
}

resource "aws_ssoadmin_permission_set" "all" {
  for_each = local.permission_sets

  name             = each.key
  description      = each.value.description
  instance_arn     = local.sso_instance_arn
  session_duration = each.value.session_duration
}

resource "aws_ssoadmin_managed_policy_attachment" "all" {
  for_each = local.ps_policies

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.all[each.value.ps].arn
  managed_policy_arn = each.value.arn
}
```

Thêm một quyền mới cho team giờ chỉ là: tạo group trong AD (mục 4.2) → thêm một dòng vào `local.grants` → `terraform apply`.

### 6.3. Thứ tự bắt buộc

`data "aws_identitystore_group"` sẽ **fail** nếu group chưa có mặt trong Identity Center. Trình tự đúng:

```text
1. Tạo group trong AD                    (PowerShell, mục 4.2)
2. Start-ADSyncSyncCycle -PolicyType Delta   → group lên Entra
3. Gán group vào enterprise app          (Graph PowerShell, mục 4.3)
4. Chờ chu kỳ SCIM (~40') hoặc "Provision on demand"
5. Xác nhận group đã có trong Identity Center
6. terraform apply
```

Bỏ qua bước 5 rồi apply là lỗi hay gặp nhất. Kiểm tra nhanh:

```bash
aws identitystore list-groups \
  --identity-store-id d-1234567890 \
  --query 'Groups[].DisplayName' --output table
```

---

## 7. ABAC – tránh bùng nổ số lượng group

Mô hình mục 6 có vấn đề về quy mô: **số group = số account × số role**. 20 account × 4 role = 80 group AD phải tạo và duy trì.

**Attribute-based access control** cắt được phần lớn: một permission set duy nhất, quyền được quyết định bằng thuộc tính user (đã sync từ AD).

```hcl
# Bật ABAC: map thuộc tính SCIM thành session tag
resource "aws_ssoadmin_instance_access_control_attributes" "this" {
  instance_arn = local.sso_instance_arn

  attribute {
    key = "Department"
    value {
      source = ["$${path:enterprise.department}"]
    }
  }

  attribute {
    key = "CostCenter"
    value {
      source = ["$${path:enterprise.costCenter}"]
    }
  }
}

# Một permission set dùng chung cho mọi team
resource "aws_ssoadmin_permission_set" "team_scoped" {
  name             = "TeamScopedAccess"
  instance_arn     = local.sso_instance_arn
  session_duration = "PT8H"
}

resource "aws_ssoadmin_permission_set_inline_policy" "team_scoped" {
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.team_scoped.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OnlyOwnDepartmentResources"
        Effect = "Allow"
        Action = ["ec2:*", "s3:*", "lambda:*"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Department" = "$${aws:PrincipalTag/Department}"
          }
        }
      },
      {
        Sid      = "MustTagNewResources"
        Effect   = "Deny"
        Action   = ["ec2:RunInstances", "s3:CreateBucket"]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestTag/Department" = "$${aws:PrincipalTag/Department}"
          }
        }
      }
    ]
  })
}
```

> Chú ý `$${...}` — dấu `$` đôi để Terraform không diễn giải, giữ nguyên `${aws:PrincipalTag/...}` cho IAM xử lý lúc runtime. Viết một `$` là policy sẽ sai hoàn toàn.

Đổi lại, ABAC đòi hỏi **kỷ luật gắn tag resource**. Nếu chưa tag đầy đủ thì đây là dự án riêng, không phải bật một phát là xong. Thực tế thường lai: group tường minh cho quyền admin/prod, ABAC cho quyền theo team ở môi trường dev.

---

## 8. Vận hành – joiner / mover / leaver

Điều đẹp nhất của mô hình này: **HR/IT không cần biết gì về AWS.**

| Sự kiện | Thao tác trong AD | Kết quả trên AWS |
|---|---|---|
| Nhân viên mới | Tạo user, thêm vào `AWS-app-dev-Developer` | Có quyền sau ~40 phút |
| Chuyển team | Đổi group thành viên | Quyền cũ mất, quyền mới có |
| Đổi phòng ban (ABAC) | Sửa attribute `department` | Session tag đổi ở lần login sau |
| Nghỉ việc | Disable account trong AD | `active = false` → mất quyền |
| Nghỉ việc gấp | Disable AD **+ thu hồi session** (bên dưới) | Mất quyền ngay |

Điểm cần lưu ý: **session đang chạy không tự chết.** User đã đăng nhập vẫn giữ credential tới hết `session_duration` (4–8 giờ theo cấu hình). Với trường hợp cần cắt ngay:

```bash
# Xoá toàn bộ session đang hoạt động của user
aws sso-admin list-application-assignments --application-arn <arn>

# Cách chắc chắn hơn: xoá session ở Identity Center console
# Users → chọn user → Active sessions → Delete session
```

Đây cũng là lý do nên đặt `session_duration = "PT4H"` cho các permission set chạm vào production, thay vì để 8–12 giờ.

Ba việc nên tự động hoá thêm:

- **Tuần tự review**: Entra ID Access Reviews cho các group `AWS-*prod*` — bắt manager xác nhận danh sách thành viên định kỳ.
- **PIM**: nhóm `AWS-all-Admin` nên là eligible chứ không permanent, user phải activate có thời hạn và lý do.
- **Cảnh báo**: EventBridge bắt sự kiện CloudTrail `CreateAccountAssignment` / `DeleteAccountAssignment` → SNS → Slack (dùng lại pattern alert ở [ví dụ 01](./01-Example-Aws-Serverless-Order-API.md)). Assignment tạo ngoài Terraform là dấu hiệu có người sửa tay.

---

## 9. Giới hạn và bẫy

| Vấn đề | Chi tiết | Cách xử lý |
|---|---|---|
| **Nested group không sync** | Entra SCIM chỉ provision thành viên trực tiếp. Group A chứa group B → member của B **không** vào Identity Center | Làm phẳng group, hoặc dùng dynamic group, hoặc chọn đường B |
| Group không xuất hiện | Chưa gán vào enterprise app | Mục 4.3, bước *Users and groups* |
| Đổi tên group AD | `data` source tra theo DisplayName → apply fail | Coi tên group là hợp đồng, đổi tên phải sửa cả Terraform |
| Đổi identity source | AWS xoá user/group và assignment gắn với chúng | Quyết định sớm, export assignment trước khi đổi |
| Tạo user tay trong Identity Center | Khi đã bật external IdP thì gần như vô nghĩa, dễ lệch trạng thái | Chỉ tạo qua AD |
| Trễ ~40 phút | Chu kỳ SCIM của Entra | *Provision on demand* khi test |
| Quota permission set | ~50 permission set/account, ~500/instance | Dùng ABAC thay vì nhân bản permission set |
| UPN `.local` | User lên cloud thành `@onmicrosoft.com` | [Doc 07 mục 10.2](./07-Aws-Centralized-DNS-Hybrid-AD-M365.md) |
| Nhầm AWS OU với AD OU | Cố map cây OU sang Organizations | Mục 1 — hai thứ khác nhau, chỉ map group |
| Terraform quản lý group | `resource "aws_identitystore_group"` xung đột với SCIM | Luôn dùng `data`, không dùng `resource` |

Con số quota nên kiểm tra lại ở trang Service Quotas của IAM Identity Center trước khi thiết kế dựa vào chúng.

---

## 10. Kiểm tra

```bash
# 1. Group đã sang Identity Center chưa
aws identitystore list-groups \
  --identity-store-id d-1234567890 \
  --query 'Groups[?starts_with(DisplayName, `AWS-`)].[DisplayName,GroupId]' \
  --output table

# 2. Thành viên của một group
GROUP_ID=$(aws identitystore list-groups --identity-store-id d-1234567890 \
  --query 'Groups[?DisplayName==`AWS-app-dev-Developer`].GroupId' --output text)

aws identitystore list-group-memberships \
  --identity-store-id d-1234567890 --group-id "$GROUP_ID"

# 3. Assignment thực tế trên một account
aws sso-admin list-account-assignments \
  --instance-arn "$SSO_INSTANCE_ARN" \
  --account-id 555555555555 \
  --permission-set-arn "$PS_ARN"

# 4. Một user nhìn thấy những account nào (chạy dưới danh nghĩa user đó)
aws sso list-accounts --access-token "$TOKEN"

# 5. Đăng nhập thử end-to-end
aws configure sso
aws sts get-caller-identity --profile app-dev
# Assumed role phải có dạng:
# arn:aws:sts::555555555555:assumed-role/AWSReservedSSO_DeveloperAccess_xxxx/nguyenva@acme.com
```

Dòng cuối là bài test quan trọng nhất — tên role chứa cả permission set lẫn UPN, xác nhận toàn bộ chuỗi AD → Entra → SCIM → assignment đã thông.

Phía Entra, xem log provisioning ở *Enterprise applications → AWS IAM Identity Center → Provisioning logs*: mỗi user/group đều có bản ghi Success/Skipped/Failure kèm lý do. Đây là nơi đầu tiên nên nhìn khi "user không thấy account nào".

---

## 11. Tóm tắt luồng

```text
AD OU          →  chỉ là phạm vi lọc cho Entra Connect (không map sang AWS)
AD group       →  Entra group  →  Identity Center group   ← cái này mới map được
Identity Center group + Permission Set + Account  =  Account Assignment
AWS Organizations OU  →  chứa account, dùng cho SCP, không liên quan tới AD
```

Một câu để nhớ: **AD group ánh xạ sang quyền; AD OU thì không ánh xạ sang gì cả.**

---

## 12. Hướng mở rộng

- **Terraform sinh group AD**: dùng provider `activedirectory` hoặc `ad` để tạo luôn group từ cùng `local.grants`, đảm bảo hai đầu không lệch.
- **Entra ID Governance**: access package cho phép user tự request quyền AWS, có approval workflow và thời hạn tự hết.
- **Just-in-time admin**: bỏ hẳn assignment `AdministratorAccess` cố định, thay bằng PIM activation hoặc AWS Systems Manager Change Manager.
- **Audit chéo**: Lambda chạy hàng tuần so `list-account-assignments` với `local.grants` trong Terraform, báo cáo phần chênh lệch.
- **Machine identity**: CI/CD **không** dùng Identity Center — dùng GitHub Actions OIDC assume IAM role trực tiếp (xem [doc 06 mục 16](./06-Aws-Landing-Zone.md)).
