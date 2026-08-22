output "enabled" {
  value = local.enabled
}

output "trail_name" {
  value = local.enabled ? aws_cloudtrail.this[0].name : null
}

output "trail_arn" {
  value = local.enabled ? aws_cloudtrail.this[0].arn : null
}

output "log_bucket" {
  value = local.enabled ? aws_s3_bucket.trail[0].id : null
}

output "log_prefix" {
  description = <<-EOT
    Duong dan trong bucket. Organization trail co them doan org-id
    ma trail thuong khong co - do la cho hay sai khi viet bucket
    policy hoac khi di tim file.
  EOT
  value       = local.enabled ? "AWSLogs/${local.org_id}/<account-id>/CloudTrail/<region>/" : null
}

output "scope" {
  value = {
    organization_trail  = true
    multi_region        = true
    data_events         = var.data_events
    log_file_validation = var.enable_log_file_validation
    retention_days      = var.log_retention_days
    object_lock         = var.enable_object_lock
  }
}

output "next_steps" {
  value = <<-EOT

    ══════════════════════ SAU KHI APPLY ══════════════════════

    1. DOI ~15 PHUT roi kiem file dau tien:

         aws s3 ls s3://${local.bucket_name}/ --recursive \
           --profile <log-archive> | head

       CloudTrail giao theo lo, khong tuc thi. Rong ngay sau apply
       la BINH THUONG.

    2. TRAIL DA GHI CHUA:

         aws cloudtrail get-trail-status --name ${local.trail_name} \
           --query '[IsLogging,LatestDeliveryTime,LatestDeliveryError]'

       IsLogging phai la true. LatestDeliveryError co gia tri thi do
       gan nhu luon la bucket policy.

    3. XAC NHAN PHU CA TO CHUC:

         aws cloudtrail describe-trails --trail-name-list ${local.trail_name} \
           --query 'trailList[0].[IsOrganizationTrail,IsMultiRegionTrail]'

       Ca hai phai la true. IsOrganizationTrail = false nghia la no
       chi ghi management account - dung vung mu lon nhat.

    4. DOI CONFIG DANH GIA LAI (~1 gio):

         aws configservice describe-aggregate-compliance-by-config-rules \
           --configuration-aggregator-name <project>-org \
           --profile <security> --region <region> \
           --query 'AggregateComplianceByConfigRules[?contains(ConfigRuleName,`cloud-trail`)]'

       cloud-trail-enabled phai chuyen tu NON_COMPLIANT sang
       COMPLIANT o moi account. Do la phep kiem chung THAT cua layer
       nay - khong phai viec trail ton tai, ma viec lop phat hien
       xac nhan no ton tai.

    5. KIEM TRA HOA DON SAU MOT TUAN:

         Cost Explorer -> loc Service = "AWS CloudTrail"

       Chi nen thay chi phi S3 storage. Thay dong CloudTrail dang ke
       nghia la data_events dang bat o dau do.

    ═══════════════════════════════════════════════════════════
    Layer nay KHONG nam trong teardown cua demo.
    ═══════════════════════════════════════════════════════════

  EOT
}
