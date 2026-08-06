variable "aws_region" {
  description = "Region để deploy lab."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Tiền tố đặt tên cho mọi resource. Chỉ dùng chữ thường, số và dấu gạch ngang."
  type        = string
  default     = "mcp-lab"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name chỉ được chứa chữ thường, số và dấu gạch ngang."
  }
}

variable "log_retention_days" {
  description = "Số ngày giữ log CloudWatch. Đặt ngắn để lab không tốn tiền."
  type        = number
  default     = 7
}

variable "enable_auth" {
  description = <<-EOT
    true  = bật Cognito JWT authorizer trên /mcp (giống production).
    false = để endpoint public — CHỈ dùng khi mới học Lab 2, và hãy destroy ngay sau đó.
  EOT
  type        = bool
  default     = true
}
