# aws-serverless-applications

Ghi chép và ví dụ Terraform về AWS: serverless workload và Landing Zone cho môi trường enterprise.

---

## Serverless workload

| # | Nội dung |
|---|---|
| [00](./docs/00-API-Gateway-Summary.md) | API Gateway – tổng hợp |
| [01](./docs/01-Example-Aws-Serverless-Order-API.md) | Order API: API Gateway + Lambda + SQS + DynamoDB + DLQ + SNS |
| [02](./docs/02-Aws-Api-gateway-core-and-Cognito-authozier.md) | API Gateway core và Cognito authorizer |
| [03](./docs/03-Amazon-AppFlow-Backup-dữ-liệu-SaaS.md) | Amazon AppFlow – backup dữ liệu SaaS |
| [04](./docs/04-Aws-lambda-function.md) | AWS Lambda |
| [05](./docs/05-Aws-sqs-queue.md) | Amazon SQS |

## Landing Zone – nền tảng

| # | Nội dung |
|---|---|
| [06](./docs/06-Aws-Landing-Zone.md) | **Landing Zone** – Organizations, OU, SCP, logging, Identity Center |
| **[20](./docs/20-Van-hanh-LZ-Remote-State-va-Quy-trinh-Thay-doi.md)** | **Vận hành LZ** – remote state, khoá state, quy trình thay đổi hằng ngày |
| **[21](./docs/21-Control-Tower-vs-DIY.md)** | **Control Tower vs DIY** – hai cách dựng nền tảng, code cả hai để đối chiếu |
| **[22](./docs/22-Nhat-ky-Trien-khai-LZ-DIY.md)** | **Nhật ký triển khai** – lần dựng thật: 25 lỗi gặp phải và cách sửa |
| [09](./docs/09-Account-Vending-Tu-Dong.md) | Account vending tự động – request as code, StackSet baseline |
| [10](./docs/10-CICD-cho-Landing-Zone-GitHub-Actions-OIDC.md) | CI/CD cho LZ – GitHub Actions + OIDC, không dùng access key |
| [11](./docs/11-Tag-Policy-va-Cost-Allocation.md) | Tag policy và cost allocation – chia bill theo team |

## Landing Zone – identity

| # | Nội dung |
|---|---|
| **[19](./docs/19-Permission-Set-cho-Landing-Zone.md)** | **Permission set** – 17 set, gán theo group, chặn đường leo thang quyền |
| [07](./docs/07-Aws-Centralized-DNS-Hybrid-AD-M365.md) | DNS hybrid với AD on-premise và Microsoft 365 |
| [08](./docs/08-Dong-bo-User-AD-sang-IAM-Identity-Center.md) | Đồng bộ user/group từ AD sang IAM Identity Center |

## Landing Zone – network

**Bắt đầu từ [17 – Design Guide](./docs/17-Network-LZ-Design-Guide.md).** Đó là tài liệu thiết kế chuẩn; 12–16 và 18 là chi tiết từng thành phần.

Mục 0 của doc 17 có **bảng trạng thái**: phần nào đã có code chạy được, phần nào mới có trên giấy.

| # | Nội dung |
|---|---|
| **[17](./docs/17-Network-LZ-Design-Guide.md)** | **Design Guide** – kiến trúc, CIDR chuẩn, bảng định tuyến TGW, chi phí, lộ trình |
| [12](./docs/12-DNS-va-VPC-Endpoint-Tap-Trung-AWS-Only.md) | DNS và VPC endpoint tập trung – môi trường thuần AWS |
| [13](./docs/13-Centralized-Ingress-Egress-Network.md) | Khoá Internet ở mọi account, tách ingress/egress VPC |
| [14](./docs/14-Ingress-Chain-CDN-PaloAlto-F5-WAF.md) | Ingress chain: CDN → Palo Alto → F5 WAF → App |
| [15](./docs/15-Security-VPC-Network-Firewall.md) | Security VPC – mọi traffic qua AWS Network Firewall |
| [16](./docs/16-Ket-noi-Doi-tac-3rd-Party-VPC-va-VPN.md) | Kết nối đối tác – 3rd-party VPC và Site-to-Site VPN |
| [18](./docs/18-Cau-hinh-F5-BIG-IP-Advanced-WAF.md) | Cấu hình F5 BIG-IP Advanced WAF – DO, AS3, WAF policy |

## Hạ tầng thường trực

Dựng một lần rồi để đó, **không nằm trong teardown của demo**.

**Chạy lần đầu: [`landing-zone/RUNBOOK.md`](./landing-zone/RUNBOOK.md)** — hướng dẫn theo thứ tự, từ tài khoản trắng đến LZ hoạt động. Các README dưới đây nói *vì sao*; runbook nói *làm gì trước, làm gì sau*.

**Đã dựng thật một lần, đi hết cả 8 giai đoạn** — [doc 22](./docs/22-Nhat-ky-Trien-khai-LZ-DIY.md) ghi lại 25 lỗi gặp phải và cách sửa, trong đó **21 lỗi nằm ở chính code của repo**. Đọc mục 6 trước khi bắt đầu để đỡ mất thời gian.

> **Layer nào đã qua lửa:** `tf-backend`, `organization`, `permission-sets`, `billing-guard` đã apply thật.
> **Chưa:** `config-detective`, `control-tower`. Đáng lưu ý vì 5 trong 13 lỗi thuộc loại `terraform validate` không bắt được — cú pháp đúng, kiểu đúng, chỉ AWS mới biết là sai.

| Layer | Nội dung | Chi phí |
|---|---|---|
| **[`landing-zone/tf-backend`](./landing-zone/tf-backend/)** | **Dựng đầu tiên.** S3 + khoá state cho mọi layer thường trực | ~$0 |
| [`landing-zone/organization`](./landing-zone/organization/) | **DIY** – Organizations, cây OU, 4 SCP. Bản dùng thật | $0 |
| [`landing-zone/control-tower`](./landing-zone/control-tower/) | Bản Control Tower để đối chiếu. **Mặc định tắt** | $0 khi tắt |
| [`landing-zone/config-detective`](./landing-zone/config-detective/) | AWS Config: lớp **phát hiện** bù cho SCP. **Mặc định tắt** | $0 khi tắt |
| [`landing-zone/billing-guard`](./landing-zone/billing-guard/) | Cost allocation tag (không hồi tố), budget cảnh báo, anomaly detection. Chạy ở management account | ~$0 |
| [`landing-zone/permission-sets`](./landing-zone/permission-sets/) | 17 permission set + 15 group + ma trận gán quyền. Chạy ở management account | $0 |
| [`landing-zone/org-trail`](./landing-zone/org-trail/) | Organization CloudTrail – phủ mọi account hiện tại và tương lai. **Mặc định tắt** | ~$0 |

## Demo chạy được

Terraform dựng lên xem rồi xoá. **Không tạo AWS account** — account không xoá được, chỉ đóng được.

| Demo | Nội dung | Chi phí |
|---|---|---|
| **[`demo/network-lz-full`](./demo/network-lz-full/)** | **Bộ chính** — TGW 4 route table, security VPC + Network Firewall, egress + NAT, ingress NLB, spoke. Kịch bản 5 bước. Chưa có Palo Alto/F5 | ~$0.34–0.77/giờ |
| [`demo/centralized-network`](./demo/centralized-network/) | Bản tối giản: TGW, egress tập trung, cách ly spoke | ~$0.21/giờ |
| [`demo/centralized-network-multiaccount`](./demo/centralized-network-multiaccount/) | Ba account: RAM share TGW, PHZ cross-account | ~$0.22/giờ |

Mỗi demo có `README.md` với kịch bản từng bước, script kiểm chứng, và phần xác nhận đã xoá sạch.

---

## Lưu ý

- Tên `acme`, IP và region trong ví dụ là placeholder — chỉnh trước khi dùng.
- Giá tiền là ước tính tham khảo, kiểm tra lại bằng AWS Pricing Calculator.
- Chạy thử ở AWS Organization sandbox trước khi áp dụng vào org production, nhất là phần SCP.
