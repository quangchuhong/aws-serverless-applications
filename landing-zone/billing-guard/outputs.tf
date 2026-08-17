output "sns_topic_arn" {
  description = "Dung lai cho canh bao khac (firewall, VPN tunnel...)"
  value       = aws_sns_topic.billing_alerts.arn
}

output "cost_allocation_tags_activated" {
  value = var.enable_cost_allocation_tags ? var.cost_allocation_tags : []
}

output "organization_id" {
  value = data.aws_organizations_organization.current.id
}

output "cost_explorer_url" {
  description = "Dashboard tap trung cho MOI account - mien phi, khong phai build gi"
  value       = "https://us-east-1.console.aws.amazon.com/costmanagement/home#/cost-explorer"
}

output "next_steps" {
  value = <<-EOT

    ══════════════════════ SAU KHI APPLY ══════════════════════

    1. XAC NHAN EMAIL
       SNS vua gui email xac nhan toi:
       ${join("\n       ", var.alert_emails)}
       Chua bam link = KHONG nhan duoc canh bao nao.

    2. CHO ~24 GIO
       Cost allocation tag moi xuat hien trong Cost Explorer.
       Kiem tra:
         aws ce list-cost-allocation-tags --status Active \
           --query 'CostAllocationTags[].[TagKey,Status]' --output table

    3. DASHBOARD TAP TRUNG - da co san, khong phai build
       ${"https://us-east-1.console.aws.amazon.com/costmanagement/home#/cost-explorer"}
       Group by: Linked Account / Service / Tag / Cost Category

    4. KIEM TRA BUDGET
         aws budgets describe-budgets \
           --account-id ${data.aws_caller_identity.current.account_id} \
           --query 'Budgets[].[BudgetName,BudgetLimit.Amount]' --output table

    ═══════════════════════════════════════════════════════════
    Layer nay KHONG nam trong teardown cua demo.
    Dung mot lan roi de do - chi phi ~$0.
    ═══════════════════════════════════════════════════════════
  EOT
}
