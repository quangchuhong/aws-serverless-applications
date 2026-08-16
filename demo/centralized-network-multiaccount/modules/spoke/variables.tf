variable "name" {
  description = "Ten spoke, vd app-dev"
  type        = string
}

variable "project" {
  type = string
}

variable "cidr" {
  type = string
}

variable "region" {
  type = string
}

variable "az" {
  type = string
}

variable "transit_gateway_id" {
  description = "TGW cua network account, da share qua RAM"
  type        = string
}

variable "supernet" {
  type = string
}

variable "enable_test_instance" {
  type    = bool
  default = true
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}
