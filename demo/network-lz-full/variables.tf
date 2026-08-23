variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "az" {
  description = "Demo dung 1 AZ de tiet kiem. Production phai >= 2 (xem doc 17)."
  type        = string
  default     = "ap-southeast-1a"
}

########################################
# Tag chuan - xem doc 11 muc 2
#
# Bon tag nay duoc bat cost allocation o landing-zone/billing-guard.
# Gan chung o day thi Cost Explorer moi group duoc theo tag.
########################################

variable "project" {
  description = "Tag Project, dong thoi la tien to dat ten resource"
  type        = string
  default     = "lz-net"
}

variable "cost_center" {
  description = "Tag CostCenter - ma phong ban chiu chi phi. Dung MA, khong dung ten (doc 11 muc 2)."
  type        = string
  default     = "CC-0000"
}

variable "owner" {
  description = "Tag Owner - email nguoi chiu trach nhiem"
  type        = string
  default     = "platform@example.com"
}

variable "environment" {
  description = "Tag Environment"
  type        = string
  default     = "sandbox"

  validation {
    condition     = contains(["dev", "staging", "prod", "sandbox"], var.environment)
    error_message = "environment phai la dev, staging, prod hoac sandbox."
  }
}

########################################
# CIDR - theo bang chuan o doc 17 muc 3
########################################

variable "ingress_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "security_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "egress_vpc_cidr" {
  type    = string
  default = "10.2.0.0/16"
}

variable "spokes" {
  description = "VPC workload. Moi spoke ton them ~$0.05/gio phi TGW attachment."
  type = map(object({
    cidr = string
  }))

  default = {
    "app-dev"  = { cidr = "10.10.0.0/16" }
    "app-prod" = { cidr = "10.20.0.0/16" }
  }
}

variable "internal_supernet" {
  description = "Dai bao trum moi VPC noi bo"
  type        = string
  default     = "10.0.0.0/8"
}

########################################
# Cong tac chi phi
########################################

variable "enable_firewall" {
  description = <<-EOT
    false = CHE DO RE (~$0.34/gio). Khong tao security VPC.
            rtb-spokes tro thang sang egress. Kiem chung duoc:
            egress tap trung, cach ly spoke, ingress NLB.
            KHONG kiem chung duoc: east-west qua firewall.

    true  = DAY DU (~$0.74/gio). Network Firewall thanh tra moi luong.
  EOT
  type        = bool
  default     = false
}

variable "firewall_mode" {
  description = "alert = chi ghi log (an toan, dung dau tien). drop = chan that."
  type        = string
  default     = "alert"

  validation {
    condition     = contains(["alert", "drop"], var.firewall_mode)
    error_message = "firewall_mode phai la 'alert' hoac 'drop'."
  }
}

variable "enable_ingress" {
  description = "Ingress VPC + NLB. Palo Alto va F5 KHONG co trong demo nay - xem README."
  type        = bool
  default     = true
}

variable "enable_cdn" {
  description = <<-EOT
    CloudFront + AWS WAF truoc NLB. Can enable_ingress = true.

    Chi phi gan nhu $0 (CloudFront free tier 1TB + 10 trieu req/thang;
    WAF ~$5/thang Web ACL + ~$1/thang moi rule group, chia theo gio).
    Phien 4 tieng khoang $0.05.

    CAI GIA THAT: apply cham ~5-15 phut, destroy cham ~15-20 phut
    vi CloudFront phai disable truoc khi delete.

    Bat len cung KHOA ORIGIN: NLB chi nhan traffic tu CloudFront.
  EOT
  type        = bool
  default     = false
}

variable "waf_mode" {
  description = "count = chi dem, khong chan (dung dau tien). block = chan that."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode phai la 'count' hoac 'block'."
  }
}

variable "waf_managed_rule_groups" {
  description = "Managed rule group cua AWS. Moi cai ~$1/thang."
  type        = list(string)

  default = [
    "AWSManagedRulesCommonRuleSet",         # OWASP co ban
    "AWSManagedRulesKnownBadInputsRuleSet", # payload khai thac da biet
    "AWSManagedRulesSQLiRuleSet",           # SQL injection
  ]
}

variable "waf_rate_limit" {
  description = "So request toi da tu mot IP trong 5 phut. Toi thieu 100."
  type        = number
  default     = 2000
}

variable "cdn_price_class" {
  description = "PriceClass_100 = US/EU (re nhat). PriceClass_200 = them chau A (do tre tot hon tu VN). PriceClass_All = toan cau."
  type        = string
  default     = "PriceClass_200"
}

variable "enable_interface_endpoints" {
  description = "Interface endpoint trong security VPC (~$0.01/gio moi cai). Can enable_firewall=true."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  type    = list(string)
  default = ["ssm", "ssmmessages", "ec2messages"]
}

########################################
# Palo Alto + F5 — PHASE SAU
#
# Mac dinh TAT. Code viet san de terraform plan kiem chung duoc,
# khi co license chi bat bien nay len.
########################################

variable "enable_appliances" {
  description = <<-EOT
    Palo Alto (qua GWLB) + F5 BIG-IP. Can enable_ingress = true.

    false (mac dinh) -> khong tao gi. IGW -> NLB -> app.
    true             -> IGW -> GWLBe -> PA -> NLB -> F5 -> TGW -> app.

    CHUA APPLY DUOC neu chua subscribe AMI tren Marketplace.

    Muon PLAN ma chua subscribe: dat pa_ami_id va f5_ami_id bang
    mot AMI bat ky, plan se bo qua data source tim AMI Marketplace.

    Chi phi khi bat: ~$3-6/gio (license tinh theo gio).
  EOT
  type        = bool
  default     = false
}

variable "pa_ami_id" {
  description = "AMI cua Palo Alto. De trong = tu tim tren Marketplace theo pa_ami_name_pattern."
  type        = string
  default     = ""
}

variable "pa_ami_name_pattern" {
  description = "Mau ten AMI Palo Alto tren Marketplace"
  type        = string
  default     = "PA-VM-AWS-11.1*"
}

variable "pa_instance_type" {
  description = "Palo Alto can toi thieu m5.xlarge"
  type        = string
  default     = "m5.xlarge"
}

variable "pa_health_check_port" {
  description = "Port health check cua GWLB toi PA. Kiem tra tai lieu PA cho phien ban ban dung."
  type        = number
  default     = 80
}

variable "pa_health_check_protocol" {
  type    = string
  default = "TCP"
}

variable "f5_ami_id" {
  description = "AMI cua F5. De trong = tu tim tren Marketplace theo f5_ami_name_pattern."
  type        = string
  default     = ""
}

variable "f5_ami_name_pattern" {
  description = <<-EOT
    Mau ten AMI F5. Ban PAYG tinh theo gio (khong can mua license truoc)
    thuong co chu 'PAYG' trong ten; ban BYOL co chu 'BYOL'.
    Xem doc 18 muc 0.
  EOT
  type        = string
  default     = "F5 BIGIP-17.1*PAYG-Adv WAF Plus 25Mbps*"
}

variable "f5_instance_type" {
  description = "F5 Advanced WAF can toi thieu m5.xlarge"
  type        = string
  default     = "m5.xlarge"
}

variable "nlb_listener_port" {
  description = "Port NLB nghe. Demo dung 80; production dung 443 voi F5 terminate TLS."
  type        = number
  default     = 80
}

variable "enable_test_instances" {
  description = "EC2 nginx trong moi spoke de kiem chung (~$0.012/gio moi cai)"
  type        = bool
  default     = true
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

########################################
# Rule east-west - DAY LA PHAN DE THU NGHIEM
########################################

variable "east_west_rules" {
  description = <<-EOT
    Cac luong spoke-to-spoke DUOC PHEP.

    Chu y: khong can them ROUTE nao cho cac luong nay.
    Route 0.0.0.0/0 -> security da phu san. Chi can rule firewall + security group.
    Bo mot dong o day roi apply lai -> luong do bi chan ngay.
  EOT

  type = list(object({
    from_cidr = string
    to_cidr   = string
    port      = number
    note      = string
  }))

  default = [
    {
      from_cidr = "10.10.0.0/16"
      to_cidr   = "10.20.0.0/16"
      port      = 80
      note      = "app-dev goi app-prod qua HTTP"
    },
  ]
}

variable "egress_allowed_domains" {
  description = "Domain duoc phep ra Internet (khop theo TLS SNI / HTTP Host)"
  type        = list(string)

  default = [
    ".amazonaws.com",
    ".amazonlinux.com", # can cho dnf install nginx
    ".amazontrust.com",
  ]
}

########################################
# DUNG DEMO NAY LAM HA TANG THUONG TRUC
########################################

variable "ephemeral" {
  description = <<-EOT
    true (mac dinh) - day la DEMO: dung len xem roi xoa.

      - moi resource mang tag Ephemeral = "true"
      - teardown.sh QUET THEO TAG DO va xoa sach
      - firewall tat delete_protection
      - ba bucket dat force_destroy = true

    Bon dieu do lam cho "dung - xem - xoa" chay tron. Chung cung lam
    cho bo nay CUC KY NGUY HIEM neu ban giu no lai lam mang that:
    mot lenh ./teardown.sh la mat toan bo, khong co lop chan nao.

    false - dung bo nay lam ha tang thuong tru:

      - BO tag Ephemeral -> teardown.sh khong con thay resource nao
      - BAT delete_protection va subnet_change_protection cua firewall
      - force_destroy = false -> bucket con object thi destroy dung lai

    Doi sang false thi terraform destroy se KHONG chay tron nua. Do
    la dung y muon - xem muc "Xoa" trong README.
  EOT
  type        = bool
  default     = true
}

variable "ingress_allowed_cidrs" {
  description = <<-EOT
    Dai IP duoc phep goi vao NLB cong 80, khi enable_cdn = false.

    Mac dinh 0.0.0.0/0 - dung cho demo va CHI dung cho demo: do la mot
    cong HTTP cong khai, khong CDN, khong WAF, khong TLS.

    Giu bo nay lam mang that thi co hai duong:
      - siet lai day, vi du ["<IP-van-phong>/32"]
      - hoac enable_cdn = true, luc do rule nay khong ton tai va chi
        prefix list cua CloudFront vao duoc

    Co check block canh bao khi ephemeral = false ma van de 0.0.0.0/0.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.ingress_allowed_cidrs) > 0
    error_message = "ingress_allowed_cidrs rong thi khong ai vao duoc NLB - dung enable_ingress = false neu do la y muon."
  }
}
