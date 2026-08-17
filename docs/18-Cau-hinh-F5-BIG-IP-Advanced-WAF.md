# Cấu hình F5 BIG-IP Advanced WAF

Ví dụ 18: Cấu hình F5 BIG-IP làm tầng WAF trong chuỗi ingress, quản lý bằng khai báo (declarative) chứ không click GUI.

> Tài liệu chi tiết. Phần hạ tầng AWS cho F5 (EC2, NLB, security group, routing) ở [14 – Ingress Chain](./14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) mục 7. Bài này nói phần **bên trong** F5.

---

## 0. Chưa có license vẫn học được – dùng bản PAYG

Nhiều người hoãn phần F5 vì nghĩ phải mua license trước. Không cần.

AWS Marketplace có BIG-IP VE ở **hai hình thức**:

| Hình thức | Trả tiền thế nào | Dùng khi |
|---|---|---|
| **BYOL** (Bring Your Own License) | Mua license từ F5, có thể mất vài tuần–tháng | Chạy production dài hạn |
| **PAYG / hourly** | **Tính theo giờ, không cam kết, không mua trước** | **Học, thử nghiệm, PoC** |

Với PAYG bạn chỉ cần **subscribe trên Marketplace** (miễn phí) rồi launch instance — tính tiền theo giờ như EC2 thường, tắt là hết.

Ước tính cho một buổi thực hành 3 tiếng:

| | Đơn giá tham khảo | 3 tiếng |
|---|---|---|
| BIG-IP VE (bundle có WAF, m5.xlarge) | ~$1–4/giờ tuỳ bundle | ~$3–12 |
| EC2 m5.xlarge bên dưới | ~$0.24/giờ | ~$0.7 |
| **Cộng** | | **~$4–13** |

Giá bundle dao động rất lớn theo throughput và tính năng — **kiểm tra giá thực tế trên trang Marketplace** cho đúng bundle bạn định dùng trước khi launch.

Ý chính: **không cần chờ license mới học được cấu hình F5.** Vài chục đô là đủ để làm quen và viết xong bộ declaration, rồi khi có license BYOL thì dùng lại y nguyên.

Palo Alto VM-Series cũng có bundle PAYG tương tự.

---

## 1. Mô hình cấu hình – hiểu chỗ này là xong một nửa

Đây là phần làm nhiều người vướng: F5 có **nhiều API khai báo khác nhau**, mỗi cái lo một tầng. Cấu hình qua GUI rồi không tự động hoá được là vì không biết cái nào làm gì.

| Thành phần | Lo phần gì | Chạy khi nào |
|---|---|---|
| **Runtime Init** | Bootstrap: cài các gói bên dưới, nạp secret, gọi DO và AS3 | Lần đầu boot, qua `user_data` |
| **DO** (Declarative Onboarding) | Hệ thống: hostname, license, DNS/NTP, VLAN, self-IP, user, HA | Một lần lúc dựng, ít khi đổi |
| **AS3** (Application Services 3) | Ứng dụng: virtual server, pool, monitor, TLS profile, gắn WAF policy | Mỗi lần thêm/đổi ứng dụng |
| **WAF policy JSON** | Luật WAF: signature, violation, URL/parameter cho phép | Mỗi lần chỉnh chính sách bảo mật |
| **TS** (Telemetry Streaming) | Đẩy log/metric ra ngoài (CloudWatch, S3, SIEM) | Một lần lúc dựng |

Quan hệ giữa chúng:

```text
user_data (Terraform)
   │
   ▼
F5 BIG-IP Runtime Init          ← điều phối viên
   │
   ├─► cài gói: DO, AS3, TS
   │
   ├─► DO declaration           ← hệ thống: hostname, license, DNS
   │
   ├─► AS3 declaration          ← ứng dụng: virtual server, pool
   │      │
   │      └─► tham chiếu WAF policy JSON  ← luật bảo mật
   │
   └─► TS declaration           ← log đi đâu
```

**Nguyên tắc: đừng cấu hình gì qua GUI.** GUI dùng để *xem* và *điều tra*, không dùng để *thay đổi*. Mọi thay đổi đi qua declaration trong Git. Cấu hình tay là thứ sẽ mất khi instance bị thay thế, và không ai biết vì sao production khác staging.

---

## 2. Runtime Init – bootstrap từ Terraform

Đây là thứ nối Terraform với F5. Đặt vào `user_data` của EC2.

### 2.1. templates/f5-runtime-init.yaml

```yaml
# Runtime Init doc tep nay luc boot lan dau.
# Kiem tra schema cho dung phien ban Runtime Init ban dung.

runtime_parameters:
  # Lay mat khau admin tu Secrets Manager, KHONG hardcode
  - name: ADMIN_PASS
    type: secret
    secretProvider:
      type: SecretsManager
      environment: aws
      version: AWSCURRENT
      secretId: ${admin_secret_name}

  # Tu lay IP cua chinh minh tu metadata
  - name: SELF_IP_EXTERNAL
    type: metadata
    metadataProvider:
      environment: aws
      type: network
      field: local-ipv4s
      index: 1

extension_packages:
  install_operations:
    - extensionType: do
      extensionVersion: 1.40.0
    - extensionType: as3
      extensionVersion: 3.45.0
    - extensionType: ts
      extensionVersion: 1.32.0

extension_services:
  service_operations:
    # 1. He thong
    - extensionType: do
      type: inline
      value:
        schemaVersion: 1.40.0
        class: Device
        async: true
        label: "Acme BIG-IP onboarding"
        Common:
          class: Tenant
          mySystem:
            class: System
            hostname: ${hostname}
            autoPhonehome: false
          myDns:
            class: DNS
            nameServers:
              - 169.254.169.253   # Route 53 Resolver cua VPC
          myNtp:
            class: NTP
            servers:
              - 169.254.169.123   # Amazon Time Sync Service
            timezone: Asia/Ho_Chi_Minh
          admin:
            class: User
            userType: regular
            password: "{{{ADMIN_PASS}}}"
            shell: bash

    # 2. Ung dung - keo tu S3 de sua khong phai thay AMI
    - extensionType: as3
      type: url
      value: ${as3_url}

    # 3. Telemetry
    - extensionType: ts
      type: url
      value: ${ts_url}

post_onboard_enabled: []
```

### 2.2. Gọi từ Terraform

```hcl
resource "aws_instance" "f5" {
  # ... phan con lai o doc 14 muc 7

  user_data = templatefile("${path.module}/templates/f5-runtime-init.yaml", {
    admin_secret_name = aws_secretsmanager_secret.f5_admin.name
    hostname          = "bigip-${each.key}.acme.internal"
    as3_url           = "https://${aws_s3_bucket.f5_config.bucket_regional_domain_name}/as3.json"
    ts_url            = "https://${aws_s3_bucket.f5_config.bucket_regional_domain_name}/ts.json"
  })
}
```

Để AS3 và WAF policy trong **S3 thay vì inline** là lựa chọn có chủ đích: sửa chính sách chỉ cần upload file mới rồi gọi lại AS3, không phải thay instance.

F5 cần quyền đọc S3 và Secrets Manager:

```hcl
resource "aws_iam_role_policy" "f5" {
  name = "f5-bootstrap"
  role = aws_iam_role.f5.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.f5_config.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.f5_admin.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents", "logs:CreateLogStream", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.f5.arn}:*"
      }
    ]
  })
}
```

---

## 3. AS3 – virtual server, pool, và gắn WAF

AS3 là nơi khai báo "ứng dụng này nghe ở đâu, đẩy về đâu, bảo vệ bằng policy nào".

### 3.1. as3.json

```json
{
  "class": "AS3",
  "action": "deploy",
  "persist": true,
  "declaration": {
    "class": "ADC",
    "schemaVersion": "3.45.0",
    "id": "acme-ingress",
    "label": "Acme ingress WAF",

    "AcmeTenant": {
      "class": "Tenant",

      "PublicApp": {
        "class": "Application",
        "template": "https",

        "serviceMain": {
          "class": "Service_HTTPS",
          "virtualAddresses": ["10.0.30.100"],
          "virtualPort": 443,
          "pool": "app_pool",
          "serverTLS": "tls_server",
          "clientTLS": "tls_client",
          "policyWAF": { "use": "acme_waf_policy" },
          "profileHTTP": { "use": "http_profile" },
          "securityLogProfiles": [{ "use": "waf_log_profile" }],
          "snat": "auto"
        },

        "app_pool": {
          "class": "Pool",
          "monitors": ["http"],
          "members": [
            {
              "servicePort": 8080,
              "serverAddresses": ["10.20.1.10", "10.20.2.11"],
              "shareNodes": true
            }
          ]
        },

        "tls_server": {
          "class": "TLS_Server",
          "certificates": [{ "certificate": "origin_cert" }]
        },

        "origin_cert": {
          "class": "Certificate",
          "certificate": { "bigip": "/Common/acme-origin.crt" },
          "privateKey": { "bigip": "/Common/acme-origin.key" }
        },

        "tls_client": {
          "class": "TLS_Client",
          "sendSNI": "app.acme.internal"
        },

        "http_profile": {
          "class": "HTTP_Profile",
          "xForwardedFor": true,
          "insertHeader": {
            "name": "X-Forwarded-Proto",
            "value": "https"
          }
        },

        "acme_waf_policy": {
          "class": "WAF_Policy",
          "url": "https://acme-f5-config.s3.ap-southeast-1.amazonaws.com/waf-policy.json",
          "enforcementMode": "transparent",
          "ignoreChanges": true
        },

        "waf_log_profile": {
          "class": "Security_Log_Profile",
          "application": {
            "localStorage": false,
            "remoteStorage": "splunk",
            "servers": [{ "address": "10.2.1.50", "port": "8088" }],
            "storageFilter": { "requestType": "illegal" }
          }
        }
      }
    }
  }
}
```

Vài chỗ đáng chú ý:

| Trường | Vì sao quan trọng |
|---|---|
| `"snat": "auto"` | F5 thay IP nguồn bằng IP của nó. **Bắt buộc** khi app ở VPC khác qua TGW — nếu không, app trả lời thẳng về client và luồng bất đối xứng |
| `xForwardedFor: true` | App muốn biết IP client thật thì phải đọc header này, vì `snat` đã che IP gốc |
| `enforcementMode: transparent` | Chỉ ghi log, **chưa chặn**. Xem mục 5 |
| `ignoreChanges: true` | AS3 không ghi đè chỉnh sửa policy làm trên GUI lúc điều tra sự cố |
| `securityLogProfiles` | Không có thì WAF chặn mà không ai biết nó chặn gì |

Áp declaration:

```bash
curl -sk -u admin:$PASS \
  -X POST https://$BIGIP_MGMT/mgmt/shared/appsvcs/declare \
  -H 'Content-Type: application/json' \
  -d @as3.json
```

---

## 4. WAF policy – phần chính

Policy JSON là nơi khai báo luật bảo mật thật sự.

### 4.1. waf-policy.json tối thiểu

```json
{
  "policy": {
    "name": "acme-waf",
    "description": "Policy cho public API",
    "template": { "name": "POLICY_TEMPLATE_RAPID_DEPLOYMENT" },
    "enforcementMode": "transparent",

    "signature-settings": {
      "signatureStaging": true,
      "minimumAccuracyForAutoAddedSignatures": "high"
    },

    "blocking-settings": {
      "violations": [
        { "name": "VIOL_ATTACK_SIGNATURE",  "alarm": true, "block": true },
        { "name": "VIOL_HTTP_PROTOCOL",     "alarm": true, "block": true },
        { "name": "VIOL_EVASION",           "alarm": true, "block": true },
        { "name": "VIOL_FILETYPE",          "alarm": true, "block": true },
        { "name": "VIOL_URL_LENGTH",        "alarm": true, "block": false },
        { "name": "VIOL_COOKIE_MODIFIED",   "alarm": true, "block": true }
      ]
    },

    "signature-sets": [
      { "name": "High Accuracy Signatures",   "alarm": true, "block": true },
      { "name": "SQL Injection Signatures",   "alarm": true, "block": true },
      { "name": "Cross Site Scripting Signatures", "alarm": true, "block": true },
      { "name": "Command Execution Signatures",    "alarm": true, "block": true }
    ],

    "data-guard": {
      "enabled": true,
      "maskData": true,
      "creditCardNumbers": true,
      "usSocialSecurityNumbers": false
    }
  }
}
```

### 4.2. Chọn template nào

| Template | Mức chặt | Dùng khi |
|---|---|---|
| `POLICY_TEMPLATE_RAPID_DEPLOYMENT` | Lỏng nhất, ít false positive | **Bắt đầu từ đây** |
| `POLICY_TEMPLATE_FUNDAMENTAL` | Trung bình | Sau khi đã tune xong rapid |
| `POLICY_TEMPLATE_COMPREHENSIVE` | Chặt nhất | Ứng dụng đã hiểu rất rõ, có thời gian tune |

Bắt đầu bằng `COMPREHENSIVE` là công thức chắc chắn để chặn nhầm hàng loạt và bị team ứng dụng yêu cầu tắt WAF.

### 4.3. Hai công tắc dễ nhầm

Đây là chỗ hay hiểu sai nhất:

| | `enforcementMode` | `signatureStaging` |
|---|---|---|
| Phạm vi | Toàn bộ policy | Riêng signature |
| `transparent` / `true` | Ghi log, không chặn | Signature mới chỉ log, không chặn |
| `blocking` / `false` | Chặn thật | Signature chặn thật |

**Cả hai đều phải bật chặn thì mới chặn.** Rất nhiều người đổi `enforcementMode` sang `blocking` rồi ngạc nhiên vì signature vẫn không chặn — vì `signatureStaging` vẫn `true`.

Staging tồn tại có lý do: signature mới (từ bản cập nhật của F5) tự động vào staging để bạn quan sát trước, tránh một bản update làm hỏng production.

---

## 5. Vòng đời policy – đây mới là phần khó

Viết policy không khó. **Sống được với nó mới khó**, vì false positive là vấn đề chính của mọi WAF.

```text
TUAN 1-2   transparent + signatureStaging = true
           → WAF chay, ghi log, KHONG chan gi
           → Doc log: request hop le nao bi danh dau nham?

TUAN 3-4   Tune: them exception cho cac false positive
           → Van transparent

TUAN 5     Tat staging cho signature da on
           signatureStaging = false
           → Van transparent, nhung gio thay ro cai gi SE bi chan

TUAN 6     enforcementMode = blocking
           → Chan that. Truc 24h dau.

LIEN TUC   Moi lan deploy ung dung co thay doi URL/parameter
           → Quay lai transparent cho phan moi
```

Nguyên tắc y hệt Network Firewall ([doc 15 mục 12](./15-Security-VPC-Network-Firewall.md)) và AWS WAF: **alert trước, block sau**.

### 5.1. Xử lý false positive

Ba cách, từ hẹp tới rộng — luôn chọn cách hẹp nhất còn dùng được:

```json
{
  "policy": {
    "urls": [
      {
        "name": "/api/upload",
        "method": "POST",
        "attackSignaturesCheck": true,
        "signatureOverrides": [
          { "signatureId": 200001834, "enabled": false }
        ]
      }
    ],

    "parameters": [
      {
        "name": "html_content",
        "level": "global",
        "attackSignaturesCheck": false,
        "valueType": "user-input",
        "dataType": "alpha-numeric"
      }
    ],

    "signature-settings": {
      "signatureStaging": false
    }
  }
}
```

| Cách | Phạm vi | Rủi ro |
|---|---|---|
| Tắt **một signature** trên **một URL** | Hẹp nhất | Thấp |
| Tắt kiểm tra cho **một parameter** | Trung bình | Trung bình |
| Tắt cả **violation type** | Rộng | Cao — hạn chế dùng |

Ghi lại **lý do** cho mỗi exception ngay trong Git commit. Sáu tháng sau không ai nhớ vì sao signature 200001834 bị tắt, và nó sẽ nằm đó mãi.

---

## 6. Quản lý bằng Git, không phải GUI

```text
f5-config/
  do/
    bigip-a.json          # he thong, moi instance mot file
    bigip-b.json
  as3/
    public-api.json       # moi ung dung mot file
    internal-portal.json
  waf-policies/
    api-policy.json       # policy tai su dung duoc
    portal-policy.json
    exceptions/
      2026-08-upload-signature.md   # ghi ly do tung exception
  ts/
    telemetry.json
```

Pipeline (dùng lại OIDC ở [doc 10](./10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md)):

```yaml
# .github/workflows/f5-config.yml
name: F5 config

on:
  pull_request:
    paths: ['f5-config/**']
  push:
    branches: [main]
    paths: ['f5-config/**']

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Kiem tra JSON hop le truoc khi day len F5
      - name: Validate JSON
        run: |
          for f in $(find f5-config -name '*.json'); do
            jq empty "$f" || { echo "JSON hong: $f"; exit 1; }
          done

      # AS3 co che do dry-run - dung no
      - name: AS3 dry run
        if: github.event_name == 'pull_request'
        run: |
          jq '.action = "dry-run"' f5-config/as3/public-api.json > /tmp/dryrun.json
          curl -sk -u "admin:${{ secrets.F5_PASS }}" \
            -X POST "https://${{ vars.F5_MGMT }}/mgmt/shared/appsvcs/declare" \
            -H 'Content-Type: application/json' \
            -d @/tmp/dryrun.json | tee /tmp/result.json
          jq -e '.results[].code < 300' /tmp/result.json

  deploy:
    needs: validate
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: f5-production      # cong approval
    steps:
      - uses: actions/checkout@v4

      - name: Upload policy len S3
        run: aws s3 sync f5-config/waf-policies/ s3://acme-f5-config/waf-policies/

      - name: Apply AS3
        run: |
          curl -sk -u "admin:${{ secrets.F5_PASS }}" \
            -X POST "https://${{ vars.F5_MGMT }}/mgmt/shared/appsvcs/declare" \
            -H 'Content-Type: application/json' \
            -d @f5-config/as3/public-api.json
```

`dry-run` của AS3 là thứ đáng dùng nhất ở đây — nó cho biết declaration sẽ đổi gì mà không thực sự đổi, giống `terraform plan`.

---

## 7. Kiểm chứng

```bash
BIGIP=https://10.0.50.10   # interface quan tri

# 1. Runtime Init da chay xong chua
curl -sk -u admin:$PASS $BIGIP/mgmt/shared/declarative-onboarding/task \
  | jq '.[] | {status: .result.status, message: .result.message}'

# 2. AS3 dang chay declaration nao
curl -sk -u admin:$PASS $BIGIP/mgmt/shared/appsvcs/declare \
  | jq '.declaration.AcmeTenant.PublicApp.serviceMain'

# 3. Virtual server co available khong
curl -sk -u admin:$PASS "$BIGIP/mgmt/tm/ltm/virtual" \
  | jq '.items[] | {name, destination}'

# 4. Pool member healthy chua
curl -sk -u admin:$PASS "$BIGIP/mgmt/tm/ltm/pool/~AcmeTenant~PublicApp~app_pool/members/stats" \
  | jq '.entries[].nestedStats.entries | {addr: .nodeName.description, state: .status_availabilityState.description}'

# 5. Policy dang o che do nao
curl -sk -u admin:$PASS "$BIGIP/mgmt/tm/asm/policies?\$select=name,enforcementMode" \
  | jq '.items[]'

# === Test tu ben ngoai ===

# 6. Request binh thuong
curl -sI https://api.acme.com/health

# 7. SQLi - transparent thi van 200 (nhung co log), blocking thi 403
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://api.acme.com/?id=1%27%20OR%20%271%27=%271"

# 8. XSS
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://api.acme.com/?q=<script>alert(1)</script>"
```

Lệnh 5 là lệnh hay quên nhất: xác nhận policy **thật sự** đang ở chế độ bạn nghĩ. Rất nhiều sự cố "WAF không chặn" hoá ra là policy vẫn ở `transparent`.

---

## 8. Bẫy hay gặp

| Triệu chứng | Nguyên nhân |
|---|---|
| **WAF không chặn dù đã `blocking`** | `signatureStaging` vẫn `true` — cần tắt cả hai |
| App không nhận được response | Thiếu `"snat": "auto"` — app trả lời thẳng client, luồng bất đối xứng |
| App thấy IP của F5, không thấy IP client | Bình thường khi có SNAT — app phải đọc `X-Forwarded-For` |
| Pool member luôn `offline` | Monitor sai port, hoặc security group của app chưa mở cho subnet F5 |
| AS3 apply xong nhưng không thấy đổi | Thiếu `"persist": true` — cấu hình mất khi reboot |
| Cấu hình biến mất sau khi thay instance | Có ai đó sửa qua GUI thay vì declaration |
| Sửa policy trên GUI bị AS3 ghi đè | Đúng như thiết kế. Muốn giữ tạm thì đặt `ignoreChanges: true` |
| Chặn nhầm hàng loạt lúc go-live | Bật `blocking` ngay từ đầu thay vì transparent 4–6 tuần |
| Không biết WAF chặn cái gì | Thiếu `securityLogProfiles` trong AS3 |
| Runtime Init fail, không rõ vì sao | Đọc `/var/log/cloud/startup-script.log` trên instance |

---

## 9. Việc còn lại khi lên production

| Việc | Ghi chú |
|---|---|
| **HA giữa hai instance** | DO có phần `ConfigSync`/`DeviceGroup`; hoặc để NLB phân tải hai instance active |
| **Quản lý certificate** | Cert của `origin.acme.com` nạp vào F5; xoay vòng định kỳ |
| **Telemetry Streaming** | Đẩy log WAF về CloudWatch/S3 ở log-archive account |
| **Bot Defense** | Tính năng riêng của Advanced WAF, cấu hình trong policy |
| **DDoS profile** | L7 DDoS ở F5, bổ sung cho Shield ở edge |
| **Backup UCS** | Sao lưu cấu hình định kỳ, dù đã có declaration trong Git |

---

## 10. Lộ trình đề xuất

```text
BUOC 1 - Hoc bang PAYG (~$10, vai tieng)
  □ Subscribe BIG-IP VE ban PAYG tren Marketplace
  □ Launch mot instance, khong can HA
  □ Chay Runtime Init + DO, vao duoc GUI
  □ Ap AS3 toi thieu: virtual server -> pool nginx
  □ Ap WAF policy transparent, ban SQLi, xem log

BUOC 2 - Viet xong bo declaration
  □ Cau truc thu muc f5-config/ nhu muc 6
  □ Pipeline validate + dry-run
  □ Tat instance PAYG di

BUOC 3 - Khi co license BYOL
  □ Doi AMI sang ban BYOL, nap regKey trong DO
  □ Phan con lai (AS3, WAF policy) dung lai y nguyen
  □ Dung 2 instance sau NLB (doc 14 muc 7)

BUOC 4 - Vong doi policy
  □ 4-6 tuan transparent + tune (muc 5)
  □ Chuyen sang blocking, truc 24h dau
```

Bước 1 đáng làm ngay: nó gỡ đúng chỗ bạn đang vướng, tốn khoảng mười mấy đô, và toàn bộ declaration viết ra dùng lại được khi có license thật.

---

> **Về độ chính xác của schema.** Các trường trong DO, AS3 và WAF policy ở trên đúng theo cấu trúc chung, nhưng **tên trường và giá trị hợp lệ thay đổi theo phiên bản**. Trước khi apply, đối chiếu với tài liệu schema của đúng phiên bản extension bạn cài (AS3 3.45, DO 1.40…). Dùng `dry-run` của AS3 để bắt lỗi schema trước khi đụng vào cấu hình thật.
