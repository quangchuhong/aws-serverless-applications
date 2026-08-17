variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "az" {
  description = "Demo dung 1 AZ de tiet kiem. Production phai dung >= 2."
  type        = string
  default     = "ap-southeast-1a"
}

########################################
# Tag chuan - xem doc 11 muc 2.
# Bon tag nay duoc bat cost allocation o landing-zone/billing-guard.
########################################

variable "project" {
  description = "Tag Project, dong thoi la tien to dat ten resource"
  type        = string
  default     = "lz-net-demo"
}

variable "cost_center" {
  description = "Tag CostCenter - ma phong ban chiu chi phi"
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
# Account - dung account DA CO SAN.
# Demo nay KHONG tao account moi (account khong xoa duoc).
########################################

variable "network_account_id" {
  description = "Account chua TGW, egress VPC, VPC endpoint tap trung"
  type        = string
}

variable "spoke_a_account_id" {
  description = "Account workload thu nhat"
  type        = string
}

variable "spoke_b_account_id" {
  description = "Account workload thu hai - de kiem chung cach ly spoke-to-spoke"
  type        = string
}

variable "execution_role_name" {
  description = "Role assume vao tung account. Account tao qua Organizations co san OrganizationAccountAccessRole."
  type        = string
  default     = "OrganizationAccountAccessRole"
}

variable "organization_id" {
  description = "o-xxxxxxxxxx - dung cho endpoint policy"
  type        = string
}

########################################
# CIDR
########################################

variable "egress_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "spoke_a_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "spoke_b_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "supernet" {
  type    = string
  default = "10.0.0.0/8"
}

########################################
# Cong tac chi phi
########################################

variable "enable_interface_endpoints" {
  description = "Interface endpoint tap trung o network account (~$0.01/gio moi cai)"
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  type    = list(string)
  default = ["ssm", "ssmmessages", "ec2messages"]
}

variable "enable_test_instances" {
  type    = bool
  default = true
}
