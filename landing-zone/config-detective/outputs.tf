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

       TERRAFORM KHONG KIEM DUOC VIEC NAY. Do duoc trong lan dung that:

         terraform state ->  ARN that, ket thuc bang UUID
         terraform plan  ->  khong doi          (Terraform noi ON)
         SNS             ->  Deleted            (khong ai nhan gi)

       Provider truyen ReturnSubscriptionArn=true nen SNS tra ARN that
       NGAY CA khi chua xac nhan. State giu ARN do, va khi SNS xoa
       subscription chua xac nhan sau 3 NGAY thi plan van sach.

       Hoi thang SNS:

         aws sns list-subscriptions-by-topic \
           --topic-arn <alert_topic> \
           --profile <security> --region ${var.region} \
           --query 'Subscriptions[].[Endpoint,SubscriptionArn]' --output table

       Cot cuoi PHAI la mot ARN ket thuc bang UUID.
         PendingConfirmation  chua bam link
         Deleted              xem duoi - DUNG voi chay -replace

       "Deleted" co hai nguyen nhan, nhin y het nhau:
         (1) chua xac nhan qua 3 ngay, SNS tu don
         (2) DIA CHI DO BI CHAN O TOPIC NAY - do tung co nguoi bam
             "unsubscribe" trong mot thu TU CHINH TOPIC DO

       (2) la chan theo TOPIC chu khong theo dia chi: cung dia chi do
       van dang ky binh thuong vao topic khac, ke ca o account khac.
       Nen "email nay van nhan canh bao billing" KHONG loai tru duoc.

       Voi (2) thi -replace KHONG BAO GIO sua duoc: SNS nhan Subscribe,
       tra ve "pending confirmation", roi xoa ngay trong vai phut.

       Phan biet bang PHEP THU, khong phai suy luan - dang ky mot dia
       chi KHAC vao CUNG topic (plus-addressing cua Gmail: cung hop
       thu, khac endpoint):

         aws sns subscribe --topic-arn <alert_topic> --protocol email \
           --notification-endpoint <ban>+lztest@gmail.com \
           --profile <security> --region ${var.region}

         sleep 60   # ListSubscriptionsByTopic la eventually consistent
         # roi list lai

       QUAN TRONG: ban ghi cu con nam do thi phep thu doc SAI. Subscribe
       cho cung endpoint se KHOP VAO ban ghi cu thay vi tao moi. Phai
       unsubscribe ban ghi cu va cho toi khi no BIEN MAT khoi bang -
       khong phai toi khi no ghi "Deleted" - roi moi thu lai.

       Dia chi moi PendingConfirmation ma cu van Deleted = dia chi cu
       bi chan. Doi alert_emails sang endpoint khac roi apply. KHONG CO
       API go chan cho email - phai qua AWS Support.

       Xem README muc "Deleted" de day du ba truong hop.

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

output "security_hub" {
  description = "Trang thai Security Hub - nguon cua duong canh bao"
  value = {
    enabled       = var.enable_security_hub
    admin_account = var.enable_security_hub ? var.security_account_id : null
    standards     = keys(local.sh_selected)

    # Duong canh bao chi song khi CA HAI cung co.
    alert_path_live = var.enable_security_hub && length(var.alert_emails) > 0
  }
}

output "guardduty" {
  description = "GuardDuty: dang chay chua, va finding co toi duoc ai khong"
  value = {
    enabled       = var.enable_guardduty
    admin_account = var.enable_guardduty ? var.security_account_id : null
    detector_id   = try(aws_guardduty_detector.security[0].id, null)

    auto_enable_members = var.guardduty_auto_enable_members
    features            = sort(var.guardduty_features)

    # GuardDuty khong co duong canh bao rieng - finding di nho Security
    # Hub. Ca hai cung bat thi finding moi toi duoc SNS.
    findings_reach_alerts = var.enable_guardduty && var.enable_security_hub
  }
}
