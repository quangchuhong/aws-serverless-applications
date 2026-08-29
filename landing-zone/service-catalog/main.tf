########################################
# SERVICE CATALOG - ep tag o THOI DIEM TAO
#
# Lop nay giai quyet dung mot thu ma cac lop khac khong lam duoc:
# nguoi tao resource bang console hoac SDK.
#
#   default_tags   chi phu thu Terraform quan
#   tag policy     chi rang buoc GIA TRI cua tag DA GAN
#   SCP            chan tao resource thieu tag, nhung chi vai action
#   Config rule    phat hien SAU KHI viec da roi
#
# TagOption la thu duy nhat lam duoc: khong chon tag thi KHONG TAO
# DUOC. Doi lai, no chi phu resource launch tu catalog.
#
# ---------------------------------------------------------------
# VI VAY: DUNG DUNG LAYER NAY DE "BAT TAG".
#
# No khong bat duoc gi neu nguoi ta van co quyen tao thang. Gia tri
# cua no den tu viec DOI CACH LAM VIEC: doi ung dung khong con quyen
# tao RDS truc tiep, ho launch product "RDS chuan cua cong ty" tu
# catalog - va product do da co san tag, ma hoa, backup, subnet dung.
#
# Chua san sang doi cach lam viec thi layer nay chi la mot portfolio
# rong khong ai dung.
# ---------------------------------------------------------------
########################################

########################################
# 1. THU VIEN TagOption
#
# Day la "kho", chua gan vao dau ca. Gan o muc 3.
#
# map(list(string)) -> phang thanh tung cap key|value, vi moi
# TagOption la MOT cap. Key co nhieu value thi tao nhieu resource,
# va do chinh la thu lam nguoi launch PHAI CHON.
########################################

locals {
  # "Environment|dev" => { key = "Environment", value = "dev" }
  tag_option_pairs = local.enabled ? merge([
    for key, values in var.tag_options : {
      for v in values : "${key}|${v}" => { key = key, value = v }
    }
  ]...) : {}

  # Key co tu 2 value tro len = nguoi launch phai chon.
  # Key co dung 1 value  = tag tu gan, nguoi dung khong thay.
  keys_forcing_choice = [
    for key, values in var.tag_options : key if length(values) > 1
  ]
}

resource "aws_servicecatalog_tag_option" "this" {
  for_each = local.tag_option_pairs

  key   = each.value.key
  value = each.value.value

  # Ngung dung mot gia tri thi dat active = false, DUNG XOA.
  # Xoa lam provisioned product dang chay mat tham chieu toi
  # TagOption cua no.
  active = true
}

########################################
# 2. Portfolio
########################################

resource "aws_servicecatalog_portfolio" "this" {
  for_each = local.enabled ? var.portfolios : {}

  name          = "${var.project}-${each.key}"
  description   = each.value.description
  provider_name = var.portfolio_provider_name
}

########################################
# 3. Gan TagOption vao PORTFOLIO, khong phai vao product
#
# Gan o portfolio thi MOI product trong do thua huong. Them product
# moi la tu co tag, khong phai nho gan lai.
#
# Gan vao tung product thi moi product moi la mot cho co the quen -
# va cho bi quen chinh la cho tag bien mat.
########################################

resource "aws_servicecatalog_tag_option_resource_association" "this" {
  for_each = local.enabled ? {
    for pair in setproduct(keys(var.portfolios), keys(local.tag_option_pairs)) :
    "${pair[0]}|${pair[1]}" => { portfolio = pair[0], tag_option = pair[1] }
  } : {}

  resource_id   = aws_servicecatalog_portfolio.this[each.value.portfolio].id
  tag_option_id = aws_servicecatalog_tag_option.this[each.value.tag_option].id
}

########################################
# 4. Chia portfolio ra to chuc
#
# share_tag_options = true LA DONG QUAN TRONG NHAT CA FILE.
#
# Mac dinh cua AWS la FALSE. Thieu no thi portfolio duoc chia sang
# account khac NHUNG TagOption o lai - nguoi ben do launch product
# ma khong bi hoi tag nao ca.
#
# Do la kieu hong te nhat: moi thu bao thanh cong, catalog chay,
# product tao duoc, va thu duy nhat ban dung ca he thong nay de lam
# thi khong xay ra.
########################################

resource "aws_servicecatalog_portfolio_share" "ou" {
  for_each = local.enabled ? {
    for pair in setproduct(keys(var.portfolios), var.share_ou_arns) :
    "${pair[0]}|${pair[1]}" => { portfolio = pair[0], ou_arn = pair[1] }
  } : {}

  portfolio_id = aws_servicecatalog_portfolio.this[each.value.portfolio].id
  type         = "ORGANIZATIONAL_UNIT"
  principal_id = each.value.ou_arn

  share_tag_options = true
}

########################################
# 5. Role de Service Catalog TAO resource
#
# LAUNCH CONSTRAINT LA THU LAM CATALOG CO NGHIA.
#
# Khong co no, nguoi launch phai TU CO QUYEN tren moi dich vu ma
# product tao ra. Ma neu ho da co quyen do thi ho tao thang duoc
# roi - va ca cai catalog thanh hinh thuc.
#
# Co launch constraint: Service Catalog assume role nay de tao, nen
# nguoi dung chi can quyen launch product. Do la luc ban thuc su
# lay lai duoc quyen tao resource.
########################################

data "aws_iam_policy_document" "sc_launch_assume" {
  count = local.enabled && var.create_launch_role ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["servicecatalog.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sc_launch" {
  count = local.enabled && var.create_launch_role ? 1 : 0

  name               = "${var.project}-sc-launch"
  description        = "Service Catalog dung role nay de tao resource cua product"
  assume_role_policy = data.aws_iam_policy_document.sc_launch_assume[0].json
}

# CloudFormation la thu THUC SU tao resource, nen role phai lam duoc
# ca hai: dieu khien stack, va tao thu trong stack.
resource "aws_iam_role_policy_attachment" "sc_launch" {
  for_each = local.enabled && var.create_launch_role ? toset(var.launch_role_policy_arns) : []

  role       = aws_iam_role.sc_launch[0].name
  policy_arn = each.value
}
