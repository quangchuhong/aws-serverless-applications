########################################
# BIEN CUA LOP VAN HANH
#
# Rat it - va do la co y. Moi thu THAY DOI hang ngay nam trong
# catalog/*.yaml, khong nam o day. Bien chi de tro toi state cua layer
# cha va chinh vai nguong an toan.
########################################

variable "state_backend" {
  description = <<-EOT
    Backend cua state layer cha.

      "local" - demo/network-lz-full chay state local (mac dinh)
      "s3"    - landing-zone/network chay backend S3

    Doi mot chu nay la du de tro lop van hanh vao LZ that.
  EOT
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "s3"], var.state_backend)
    error_message = "state_backend phai la 'local' hoac 's3'."
  }
}

variable "state_config" {
  description = <<-EOT
    Cau hinh backend, dua cho terraform_remote_state.

      local: de TRONG. Mac dinh la "$${path.module}/../terraform.tfstate",
             tuc file state cua thu muc cha - tinh theo VI TRI FILE .tf
             chu khong theo thu muc dang chay.

             Khai "path" o day chi khi state cua layer cha nam cho khac.
             Duong dan tuong doi khai o day duoc giai theo THU MUC DANG
             CHAY, nen dung duong dan tuyet doi cho chac.

      s3   : { bucket = "...", key = "network/terraform.tfstate", region = "..." }
  EOT
  type        = map(string)
  default     = {}
}

variable "aws_profile" {
  description = <<-EOT
    Profile dung de TAO RESOURCE (rule group, route, endpoint, DNS).

    KHAC voi profile trong khoi backend o versions.tf: cai do de doc
    ghi STATE, thuong tro toi account chua bucket. Cai nay tro toi
    account chua ha tang mang.

    De trong = chuoi giai credential mac dinh. Luu y bien moi truong
    AWS_ACCESS_KEY_ID/AWS_PROFILE dung TRUOC profile khai o day.

    Lech account thi plan dung lai o precondition trong main.tf, chu
    khong tao nham resource.
  EOT
  type        = string
  default     = ""
}

variable "catalog_dir" {
  description = "Thu muc chua cac file YAML. Doi khi muon chay nhieu moi truong tu mot ban code."
  type        = string
  default     = "catalog"
}

variable "rule_group_capacity" {
  description = <<-EOT
    Capacity cua rule group east-west do lop nay quan.

    DAT ROI THI DUNG DOI. capacity la thuoc tinh BAT BIEN cua
    aws_networkfirewall_rule_group: sua no la Terraform XOA rule group
    va tao lai. Ma rule group dang duoc firewall policy tham chieu qua
    ARN, nen:

      - ARN moi != ARN cu
      - var.ops_rule_group_arns ben layer cha van tro ARN cu
      - apply that bai giua chung, va trong khoang do policy tham chieu
        mot rule group da bien mat

    Nen dat rong ngay tu dau. 1000 capacity ~ 1000 rule mot chieu; phi
    cua capacity khong dung la $0 - Network Firewall tinh tien theo gio
    endpoint va GB xu ly, khong theo capacity.

    lint.sh canh bao khi da dung qua 80%.
  EOT
  type        = number
  default     = 1000

  validation {
    condition     = var.rule_group_capacity >= 100 && var.rule_group_capacity <= 30000
    error_message = "rule_group_capacity trong khoang 100..30000."
  }
}

variable "sid_base" {
  description = <<-EOT
    Goc danh so sid cho rule sinh tu catalog.

    sid duoc tinh tu SO TRONG ID cua rule, khong phai tu vi tri trong
    danh sach:

      fw-0042  ->  sid 20042

    Day la diem khac quan trong so voi east_west_rules ben layer cha,
    cho do dung `1000 + i`. Voi cach do, chen mot rule vao GIUA danh
    sach la doi sid cua moi rule dung sau no - rules_string doi hoan
    toan, va o STRICT_ORDER thi ca thu tu danh gia cung doi. Mot thay
    doi dang le chi them mot dong lai thanh viet lai ca rule group.

    Tinh tu id thi chen o dau cung khong anh huong ai, va sid trong
    log alert luon tra nguoc ve dung mot dong trong YAML - ke ca sau
    khi rule khac bi xoa.

    20000 de cach xa dai cua layer cha (1000-1999).
  EOT
  type        = number
  default     = 20000
}

variable "allow_expired_rules" {
  description = <<-EOT
    Cho phep apply khi trong catalog con rule DA QUA HAN.

    Rule qua han KHONG bi tu dong go. Co chu y: go mot rule firewall
    luc nua dem vi khong ai gia han ticket la mot su co san sang xay
    ra, va no se xay ra vao dung luc khong ai truc.

    Thay vao do, qua han la mot TIN HIEU:
      - lint.sh thoat khac 0
      - check "no_expired_rules" bao khi plan
      - CI chay lint theo lich, nen no noi len ke ca khi khong ai sua gi

    Viec go van la mot commit co nguoi duyet. Dat bien nay = true de
    apply tam trong khi cho ticket gia han.
  EOT
  type        = bool
  default     = false
}
