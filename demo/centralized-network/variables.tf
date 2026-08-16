variable "region" {
  description = "Region chay demo"
  type        = string
  default     = "ap-southeast-1"
}

variable "azs" {
  description = "Hai AZ. Demo chi dung azs[0] cho NAT/endpoint de tiet kiem; azs[1] chi dung khi bat ALB (ALB bat buoc 2 AZ)."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "project" {
  description = "Tien to dat ten resource"
  type        = string
  default     = "lz-net-demo"
}

########################
# CIDR
########################

variable "ingress_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "egress_vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "spokes" {
  description = "Cac VPC workload. Moi spoke ton them ~$0.05/gio phi TGW attachment."
  type = map(object({
    cidr = string
  }))

  default = {
    "app-dev"  = { cidr = "10.10.0.0/16" }
    "app-prod" = { cidr = "10.20.0.0/16" }
  }
}

variable "supernet" {
  description = "Dai bao trum moi VPC trong demo, dung cho route va security group"
  type        = string
  default     = "10.0.0.0/8"
}

########################
# Cong tac bat/tat theo chi phi
########################

variable "enable_ingress" {
  description = "Dung ingress VPC + ALB. Them ~$0.07/gio (1 TGW attachment + ALB). Tat de tiet kiem khi chi muon xem luong egress."
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Tao interface endpoint tap trung. Them ~$0.01/gio moi endpoint. Bat o buoc 2 cua kich ban demo."
  type        = bool
  default     = false
}

variable "interface_endpoint_services" {
  description = "Service tao interface endpoint. Ba cai dau la bo ba bat buoc cua Session Manager."
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages"]
}

variable "enable_test_instance" {
  description = "EC2 t3.micro trong spoke dau tien de kiem chung duong mang (~$0.012/gio)"
  type        = bool
  default     = true
}

variable "test_instance_type" {
  type    = string
  default = "t3.micro"
}
