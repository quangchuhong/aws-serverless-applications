#!/usr/bin/env bash
#
# In ra khoi backend cua lop nay, DUNG TU CAU HINH THAT cua layer cha.
#
# VI SAO CAN
#
# Chep tay backend cua layer cha va chi doi "key" nghe rat de, va no
# sai o dung mot cho khong ai nghi toi: cau hinh backend co the mang
# role_arn, profile, hoac assume_role. Thieu nhung dong do thi
# Terraform van cau hinh backend thanh cong, van bao "Successfully
# configured the backend", roi that bai o buoc doc state:
#
#   Error refreshing state: ... HeadObject ... StatusCode: 403
#   api error Forbidden: Forbidden
#
# 403 do KHONG phai vi key sai. No la vi lop nay dang goi S3 bang MOT
# DANH TINH KHAC voi layer cha - credential mac dinh trong shell, thay
# vi vai tro ma layer cha vao. Cung mot bucket, cung mot vung, khac
# nguoi goi.
#
# Va vi S3 tra 403 chu khong phai 404 khi thieu quyen ListBucket,
# thong bao khong phan biet duoc ba nguyen nhan hoan toan khac nhau:
#   - key nam ngoai prefix duoc cap
#   - goi bang danh tinh khac
#   - bucket khong ton tai o account do
#
# Script nay bo han viec doan: doc thang cau hinh Terraform da ghi
# luc `init` cua layer cha, giu nguyen moi dong, chi doi "key".

set -uo pipefail
cd "$(dirname "$0")" || exit 1

CACHE="../.terraform/terraform.tfstate"

if [[ ! -s "$CACHE" ]]; then
  echo "Khong doc duoc $CACHE"
  echo
  echo "File nay do 'terraform init' cua layer cha ghi ra. Chua co nghia la"
  echo "layer cha chua init trong ban sao nay. Chay truoc:"
  echo
  echo "  cd .. && terraform init && cd ops && ./backend-hint.sh"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Can jq. Cai: brew install jq"
  exit 1
fi

TYPE=$(jq -r '.backend.type // ""' "$CACHE")
if [[ -z "$TYPE" || "$TYPE" == "local" ]]; then
  echo "Layer cha dung backend '${TYPE:-local}' - state nam tren dia."
  echo "Lop nay khong can khoi backend nao ca."
  exit 0
fi

PARENT_KEY=$(jq -r '.backend.config.key // ""' "$CACHE")

# Key cua lop nay: CUNG THU MUC voi layer cha, them mot cap "ops".
#
#   network/terraform.tfstate       -> network/ops/terraform.tfstate
#   network/demo/terraform.tfstate  -> network/demo/ops/terraform.tfstate
#
# Cung thu muc la bat buoc, khong phai cho gon: bucket state cua
# landing-zone/tf-backend cap quyen THEO PREFIX (mot account mot
# prefix). Key nam ngoai prefix do khong co dong Allow nao phu.
if [[ -n "$PARENT_KEY" && "$PARENT_KEY" == */* ]]; then
  OPS_KEY="${PARENT_KEY%/*}/ops/terraform.tfstate"
else
  OPS_KEY="ops/terraform.tfstate"
fi

echo
echo "Layer cha dung backend \"$TYPE\", key: ${PARENT_KEY:-（khong co）}"
echo
echo "Dan khoi sau vao khoi terraform { } trong ops/versions.tf:"
echo
echo "  backend \"$TYPE\" {"

# In MOI khoa cua layer cha, giu nguyen kieu. Doi duy nhat "key".
#
# Giu ca role_arn / profile / assume_role: do chinh la nhung dong
# quyet dinh lop nay goi S3 bang danh tinh nao, va cung la nhung dong
# hay bi bo quen nhat khi chep tay.
jq -r --arg opskey "$OPS_KEY" '
  .backend.config // {}
  | to_entries
  | map(select(.value != null))
  | map(if .key == "key" then {key: "key", value: $opskey} else . end)
  | sort_by(.key)[]
  | if (.value | type) == "string"
    then "    \(.key) = \"\(.value)\""
    else "    \(.key) = \(.value | tojson)"
    end
' "$CACHE"

echo "  }"
echo
echo "Roi:"
echo "  terraform init -reconfigure"
echo
echo "Neu VAN 403 sau khi dan nguyen khoi nay, nguyen nhan khong con la"
echo "cau hinh. Phep do phan biet, hai lenh, chay ngay:"
echo
BKT=$(jq -r '.backend.config.bucket // "?"' "$CACHE")
PREFIX="${PARENT_KEY%/*}"
echo "  # A. Object DA TON TAI (cua layer cha)"
echo "  aws s3api head-object --bucket $BKT --key '$PARENT_KEY'"
echo
echo "  # B. Object CHUA TON TAI, cung prefix"
echo "  aws s3api head-object --bucket $BKT --key '$PREFIX/khong-ton-tai'"
echo
echo "  A duoc, B tra 403  -> Da ro. Xem muc duoi."
echo "  A cung 403         -> Shell dang dung danh tinh khac layer cha:"
echo "                        aws sts get-caller-identity"
echo
echo "-------------------------------------------------------------"
echo "A DUOC MA B 403: THIEU s3:ListBucket, KHONG PHAI THIEU QUYEN KEY"
echo
echo "S3 chi tra 404 cho mot object khong ton tai khi nguoi goi co"
echo "s3:ListBucket tren bucket. Khong co thi no tra 403 - de khong"
echo "tiet lo ca viec object do co ton tai hay khong."
echo
echo "landing-zone/tf-backend CO cap s3:ListBucket, nhung kem dieu kien:"
echo
echo "    Condition = { StringLike = { \"s3:prefix\" = [\"<ten>/*\"] } }"
echo
echo "Ma s3:prefix chi co mat trong yeu cau LIST. HeadObject khong phai"
echo "lenh list, nen khoa do KHONG CO trong ngu canh, StringLike khong"
echo "khop, va ListBucket coi nhu khong duoc cap."
echo
echo "Hau qua: moi key DA TON TAI thi doc duoc (nho s3:GetObject tren"
echo "<bucket>/<ten>/*), con key CHUA TON TAI thi 403. Tuc la moi layer"
echo "MOI deu hong o lan init dau tien, va chi lan dau."
echo
echo "Hai cach sua:"
echo
echo "  1. TAO SAN OBJECT RONG - khong dung toi layer dung chung"
echo
echo "     aws s3api put-object --bucket $BKT \\"
echo "       --key '$PREFIX/ops/terraform.tfstate'"
echo
echo "     Khong co --body nen object rong. Terraform doc payload rong"
echo "     la coi nhu chua co state - dung cai no can o lan init dau."
echo "     Chi phai lam MOT LAN cho moi layer moi."
echo
echo "  2. BO DIEU KIEN s3:prefix khoi statement ListBucket"
echo "     (landing-zone/tf-backend/main.tf, Sid ListBucketFor*)"
echo
echo "     Sua han goc, nhung phai apply mot layer dung chung cho ca to"
echo "     chuc. Doi lai: account do nhin thay TEN KEY cua cac prefix"
echo "     khac. KHONG doc duoc noi dung - quyen object van theo prefix."
echo "     Ro ri ten key la nho, nhung no co that, nen day la mot lua"
echo "     chon co danh doi chu khong phai mot ban sua hien nhien."
echo
