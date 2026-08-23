output "enabled" {
  value = local.enabled
}

output "snapshot_bucket" {
  description = "Bucket nhan Config snapshot, o account log archive"
  value       = one(aws_s3_bucket.config[*].id)
}

output "object_lock" {
  description = "Object Lock - thu chan viec xoa bang chung. Chi bat duoc luc tao bucket."
  value = local.enabled && var.enable_object_lock ? {
    mode = "COMPLIANCE"
    days = var.object_lock_retention_days
  } : null
}

output "aggregator" {
  description = "Aggregator o security account - nguon du lieu cho moi dashboard tuan thu"
  value       = one(aws_config_configuration_aggregator.org[*].name)
}

output "organization_rules" {
  description = "Rule dang ap cho toan to chuc"
  value       = keys(var.organization_rules)
}

output "recording_scope" {
  description = "Pham vi ghi - ba con so quyet dinh chi phi"
  value = {
    frequency          = var.recording_frequency
    resource_types     = length(var.resource_types)
    continuous_types   = length(var.continuous_recording_types)
    target_ous         = length(var.recorder_target_ous)
    aggregator_regions = var.aggregator_regions
    excluded_accounts  = length(var.excluded_accounts)
  }
}

output "alert_topic" {
  value = one(aws_sns_topic.alerts[*].arn)
}

output "next_steps" {
  value = <<-EOT

    1. XAC NHAN EMAIL, ROI KIEM LAI BANG LENH.

       SNS gui thu xac nhan toi tung dia chi trong alert_emails.
       CHUA BAM LINK = KHONG NHAN DUOC CANH BAO NAO.

       TERRAFORM KHONG KIEM DUOC VIEC NAY. Provider luu ID la chuoi
       "pending confirmation" chu khong phai ARN that, nen lan refresh
       sau no khong thay ban ghi da bien mat. Ket qua:

         terraform plan  ->  khong doi          (Terraform noi ON)
         SNS             ->  Deleted            (khong ai nhan gi)

       Va SNS TU XOA subscription chua xac nhan sau 3 NGAY. Bam link
       muon hon la link vo dung, khong bao gi.

       Hoi thang SNS:

         aws sns list-subscriptions-by-topic \
           --topic-arn <alert_topic> \
           --profile <security> --region ${var.region} \
           --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table

       Cot cuoi PHAI la mot ARN ket thuc bang UUID.
         PendingConfirmation  chua bam link
         Deleted              da qua 3 ngay, phai tao lai:

         terraform apply -replace='aws_sns_topic_subscription.email["<email>"]'

       KHONG dung 'aws sns publish' de kiem. No tra ve MessageId ke ca
       khi topic khong co subscriber nao - lenh bao OK va thu roi vao
       hu khong.

    2. KIEM TRA RECORDER DA CHAY o vai account:

         aws configservice describe-configuration-recorder-status \
           --profile <account> --region ${var.region}
         # recording: true, lastStatus: SUCCESS

    3. KIEM TRA GIAO FILE VAO S3 (doi ~24 gio voi TwentyFour_Hours):

         aws s3 ls s3://${local.bucket_name}/ --recursive --profile <log-archive> | head

       Rong sau 24 gio = gan nhu luon la bucket policy hoac quyen KMS.
       Xem: aws configservice describe-delivery-channel-status

    4. XEM TRANG THAI TUAN THU TU AGGREGATOR:

         aws configservice describe-aggregate-compliance-by-config-rules \
           --configuration-aggregator-name ${var.project}-org \
           --profile <security> --region ${var.region}

       Rule o trang thai INSUFFICIENT_DATA nghia la recorder KHONG ghi
       loai resource ma rule do kiem tra - im lang, va rat de nham la
       "moi thu deu on".

    5. DO CHI PHI SAU MOT TUAN roi moi mo rong pham vi:

         Cost Explorer -> loc Service = "AWS Config"
         -> group by Linked Account

       Mo rong tung buoc: them region, hoac them resource type, hoac
       bo DAILY. Moi lan mot thu, do lai truoc khi lam tiep.

  EOT
}
