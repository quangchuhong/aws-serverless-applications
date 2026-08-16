variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "az" {
  description = "Demo dung 1 AZ de tiet kiem. Production phai >= 2 (xem doc 17)."
  type        = string
  default     = "ap-southeast-1a"
}

variable "project" {
  type    = string
  default = "lz-net"
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

variable "enable_interface_endpoints" {
  description = "Interface endpoint trong security VPC (~$0.01/gio moi cai). Can enable_firewall=true."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  type    = list(string)
  default = ["ssm", "ssmmessages", "ec2messages"]
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
