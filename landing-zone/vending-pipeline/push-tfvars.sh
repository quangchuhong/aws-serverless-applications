#!/usr/bin/env bash
#
# DAY terraform.tfvars CUA CAC LAYER LEN KHO CUA PIPELINE
#
# ---------------------------------------------------------------
# TAI SAO CAN SCRIPT NAY
#
# .gitignore loai terraform.tfvars khoi repo (no chua account ID,
# email, ma phong ban), nen ban checkout cua CodeBuild khong co no.
#
# Va thieu no KHONG gay loi: ba trong bon layer khong co bien bat
# buoc nao. `terraform plan` chay thanh cong voi catalog = {},
# spokes = {}, ou_ids = {} tren DUNG state that - tuc mo ta viec XOA
# moi thu dang co. Buildspec dung o day bang mot loi cung.
#
# ---------------------------------------------------------------
# CHAY O DAU
#
# Tu may CUA BAN, voi credential cua account MANAGEMENT. Khong phai
# tu CodeBuild: role CodeBuild bi Deny tuong minh quyen ghi vao
# bucket nay (xem iam.tf, "KhongGhiDeCauHinhCuaChinhMinh").
#
#   cd landing-zone/vending-pipeline
#   ./push-tfvars.sh
#
# Chay lai moi khi ban sua tfvars cua bat ky layer nao. Quen chay =
# pipeline chay tren cau hinh CU, va khong co gi bao dieu do.
#
# bash, khong phai zsh: zsh coi "$X:r" la mot toan tu bien doi tham
# so va se cat chuoi - da lam hong mot lenh assume-role hom 7/9.
#
set -euo pipefail

cd "$(dirname "$0")"

LAYERS=(
  "landing-zone/account-baseline"
  "landing-zone/network"
  "landing-zone/config-detective"
  "landing-zone/permission-sets"
)

REGION=$(terraform output -raw region 2>/dev/null || echo "ap-southeast-1")

BUCKET=$(terraform output -raw tfvars_bucket 2>/dev/null || true)
if [ -z "$BUCKET" ]; then
  echo "LOI: khong doc duoc output tfvars_bucket."
  echo ""
  echo "Hai nguyen nhan:"
  echo "  1. Layer vending-pipeline chua apply, hoac enable = false"
  echo "  2. Ban dang o nham thu muc - script nay chay o landing-zone/vending-pipeline"
  exit 1
fi

########################################
# Kiem danh tinh TRUOC khi ghi
#
# Ghi nham bucket cua mot account khac khong the xay ra (ten bucket
# co account ID), nhung chay bang mot profile khong co quyen thi loi
# hien ra o giua chung - vai file da len, vai file chua. Kiem truoc.
########################################
WHO=$(aws sts get-caller-identity --query Arn --output text)
echo "Danh tinh : $WHO"
echo "Bucket    : $BUCKET"
echo "Vung      : $REGION"
echo ""

THIEU=""
for L in "${LAYERS[@]}"; do
  if [ ! -f "../../$L/terraform.tfvars" ]; then
    THIEU="${THIEU}
  $L/terraform.tfvars"
  fi
done

if [ -n "$THIEU" ]; then
  echo "LOI: thieu tfvars o may nay:${THIEU}"
  echo ""
  echo "Moi layer trong pipeline PHAI co tfvars. Layer nao ban chua"
  echo "dung thi tao mot file toi thieu tu terraform.tfvars.example -"
  echo "dung bo qua no, vi bo qua nghia la stage do plan bang gia tri"
  echo "mac dinh va doi xoa moi thu."
  exit 1
fi

for L in "${LAYERS[@]}"; do
  SRC="../../$L/terraform.tfvars"
  KEY="tfvars/$L/terraform.tfvars"

  printf '%-34s -> s3://%s/%s\n' "$L" "$BUCKET" "$KEY"

  # Khong dung `aws s3 cp --quiet 2>/dev/null`: giau loi o day nghia
  # la script bao xong trong khi CodeBuild se doc mot file cu.
  aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$KEY" \
    --body "$SRC" \
    --region "$REGION" \
    --query 'VersionId' --output text \
    | sed 's/^/    version: /'
done

echo ""
echo "Xong. Kiem lai bang:"
echo "  aws s3 ls s3://$BUCKET/tfvars/ --recursive --region $REGION"
echo ""
echo "LUU Y: pipeline doc file nay o LAN CHAY SAU. Lan dang chay (neu"
echo "co) van dung ban cu."
