output "vpc_id" {
  value = aws_vpc.this.id
}

output "cidr" {
  value = aws_vpc.this.cidr_block
}

output "attachment_id" {
  description = "Dung o network account de gan vao TGW route table"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

# one() tra ve phan tu duy nhat, hoac null khi count = 0.
# Dung [0] o day se loi khi enable_test_instance = false.
output "test_instance_id" {
  value = one(aws_instance.test[*].id)
}

output "test_instance_private_ip" {
  value = one(aws_instance.test[*].private_ip)
}
