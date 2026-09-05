#!/usr/bin/env bash
#
# Ghi file backend.hcl cho moi layer, lay tu output cua tf-backend.
#
# Khong sua file .tf nao ca - chi tao backend.hcl. Viec chuyen state
# van do BAN chay tay, co doc ky truoc khi dong y:
#
#   cd <layer> && terraform init -migrate-state -backend-config=backend.hcl
#
# Chay lai bao nhieu lan cung duoc (idempotent).
#
#   ./wire-backends.sh           ghi tat ca layer
#   ./wire-backends.sh --dry-run chi in ra, khong ghi
#
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT=$(cd ../.. && pwd)

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }
grey()  { printf '\033[90m%s\033[0m\n' "$*"; }

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Thieu $cmd"; exit 1; }
done

if [ ! -d .terraform ]; then
  red "Chua chay terraform init trong thu muc nay."
  echo "  terraform init"
  exit 1
fi

########################################
# PHUC HOI: backend.tf mat nhung state van o S3
#
# Xay ra khi backend.tf bi xoa (no gitignore nen git reset/clean hay
# quet phai), trong khi .terraform van nho backend s3.
#
# Vong lap: script can DOC STATE de sinh backend.tf, ma doc state lai
# CAN backend.tf. Go bang cach dung backend.hcl da co san - no cung
# gitignore nhung nam o cho khac, thuong con nguyen.
########################################

BACKEND_TF_BODY='# File nay do wire-backends.sh sinh ra - dung sua tay, dung commit.
# Gia tri that nam trong backend.hcl:
#   terraform init -backend-config=backend.hcl

terraform {
  backend "s3" {}
}'

if [ ! -f backend.tf ] && [ -f backend.hcl ]; then
  if ! terraform state list >/dev/null 2>&1; then
    amber "backend.tf khong co nhung backend.hcl van con, va state doc"
    amber "khong duoc -> nhieu kha nang backend.tf bi xoa nham."
    echo
    echo "$BACKEND_TF_BODY" > backend.tf
    green "Da dung lai backend.tf."
    echo
    echo "Chay lai hai lenh nay roi goi lai script:"
    echo
    echo "  terraform init -reconfigure -backend-config=backend.hcl"
    echo "  ./wire-backends.sh"
    echo
    exit 0
  fi
fi

########################################
# Phan biet ba tinh huong khac nhau, thay vi bao chung mot cau.
#
# 1. State rong          -> chua apply (hoac apply that bai)
# 2. Co state, khong co output -> apply mot phan
# 3. Co output           -> chay tiep binh thuong
########################################

echo "Kiem tra state..."

if ! state_out=$(terraform state list 2>&1); then

  # Tinh huong rieng, va la tinh huong hay gap nhat: nguoi dung bo
  # comment backend "s3" {} TRUOC khi apply. Bucket chua ton tai ma
  # da bao Terraform cat state vao do.
  if echo "$state_out" | grep -q "Backend initialization required"; then
    red "Co backend.tf nhung chua apply lan nao."
    echo
    echo "Vong lap con ga - qua trung: layer nay TAO RA bucket chua state,"
    echo "nen lan dau BAT BUOC chay bang state LOCAL."
    echo
    amber "Cach sua (khong mat gi - chua co state nao de mat):"
    echo
    echo "  rm backend.tf"
    echo "  terraform init -reconfigure"
    echo "  terraform apply"
    echo "  ./wire-backends.sh          # sinh lai backend.tf"
    echo "  terraform init -migrate-state -backend-config=backend.hcl"
    echo
    exit 1
  fi

  red "Khong doc duoc state. Terraform bao:"
  echo
  echo "$state_out" | sed 's/^/    /'
  exit 1
fi

if [ -z "$state_out" ]; then
  red "State RONG - chua co resource nao."
  echo
  echo "Nghia la terraform apply chua chay, hoac chay that bai giua chung."
  echo
  echo "  terraform plan     # xem se tao gi"
  echo "  terraform apply    # tao that"
  echo
  echo "Roi quay lai chay ./wire-backends.sh"
  exit 1
fi

echo "  $(echo "$state_out" | wc -l | tr -d ' ') resource trong state"
echo
echo "Doc output backend_hcl..."

# KHONG nuot stderr - neu loi thi phai thay Terraform noi gi
if ! configs=$(terraform output -json backend_hcl 2>&1); then
  red "Khong doc duoc output backend_hcl. Terraform bao:"
  echo
  echo "$configs" | sed 's/^/    /'
  echo
  echo "State co resource nhung khong co output nay - thuong la apply"
  echo "dung giua chung. Chay lai:"
  echo
  echo "  terraform apply"
  exit 1
fi

if ! echo "$configs" | jq empty >/dev/null 2>&1; then
  red "Output khong phai JSON hop le:"
  echo "$configs" | head -5 | sed 's/^/    /'
  exit 1
fi

if [ "$(echo "$configs" | jq 'length')" = "0" ]; then
  red "Output backend_hcl rong - local.layers khong co layer nao."
  exit 1
fi

bucket=$(terraform output -raw bucket)
echo "Bucket: $bucket"
echo

written=0; skipped=0

while read -r layer; do
  target_dir="$REPO_ROOT/$layer"
  target="$target_dir/backend.hcl"

  if [ ! -d "$target_dir" ]; then
    amber "BO QUA  $layer  (thu muc chua ton tai)"
    skipped=$((skipped + 1))
    continue
  fi

  body=$(echo "$configs" | jq -r --arg k "$layer" '.[$k]')

  content="# File nay do wire-backends.sh sinh ra - dung sua tay.
# Sinh lai: cd landing-zone/tf-backend && ./wire-backends.sh
#
# Dung:
#   terraform init -backend-config=backend.hcl
#
$body"

  if [ "$DRY_RUN" = "1" ]; then
    echo "--- $layer/backend.hcl ---"
    echo "$content"
    echo
    continue
  fi

  if [ -f "$target" ] && [ "$(cat "$target")" = "$content" ]; then
    echo "khong doi  $layer/backend.hcl"
  else
    echo "$content" > "$target"
    green "ghi        $layer/backend.hcl"
  fi

  if [ ! -f "$target_dir/backend.tf" ] || [ "$(cat "$target_dir/backend.tf")" != "$BACKEND_TF_BODY" ]; then
    echo "$BACKEND_TF_BODY" > "$target_dir/backend.tf"
    green "ghi        $layer/backend.tf"
  fi

  written=$((written + 1))
done < <(echo "$configs" | jq -r 'keys[]')

########################################
# LAYER CO TREN DIA MA KHONG CO TRONG STATE
#
# backend_hcl la OUTPUT cua Terraform, va output nam trong STATE.
# Them mot dong vao local.layers thoi thi chua du - phai apply lai
# layer tf-backend de state biet.
#
# Bo qua buoc do thi script nay chay xong binh thuong, chi lang le
# thieu mot layer. Khong loi, khong canh bao - dung loai hong ma
# khong keu da gap suot ca du an.
########################################

# Ten layer duoc gom bang XUONG DONG, khong phai dau cach.
#
# Truoc day khoi nay gom bang dau cach roi in bang `for m in $missing`.
# Mot thu muc co dau cach trong ten - vi du mot cau lenh bi dan nham
# vao `mkdir` - bi tach thanh muc: dem bao "1 layer" trong khi ben
# duoi in ra muoi mot dong. Con so dung, danh sach sai, va nguoi doc
# tin vao danh sach.
missing=""
n_missing=0

########################################
# Demo CO Y dung state local - khong phai thieu sot.
#
# Dung-xem-xoa thi state tren dia la du, va dua chung vao bucket chi
# lam ban them. Khong khai o day thi phep kiem ben duoi keu chung
# moi lan chay - va mot canh bao keu mai ve thu khong sai la cach
# chac chan nhat de nguoi ta thoi doc canh bao.
#
# Bo mot dong khoi day khi demo do duoc giu lai lam ha tang thuong
# tru (ephemeral = false), giong landing-zone/network.
########################################
LOCAL_STATE_LAYERS="
demo/centralized-network
demo/centralized-network-multiaccount
"

# Quet CA landing-zone LAN demo, va them mot cap long ben trong demo.
#
# Truoc day vong lap nay chi nhin landing-zone/*/. Nghia la mot lop
# nam trong demo - vi du landing-zone/network/ops - khong bao gio bi
# hoi toi, va phep kiem "co tren dia ma khong co trong state" im lang
# bo qua dung loai thu muc no sinh ra de bat.
#
# Chinh no da bo sot landing-zone/network/ops.
for d in "$REPO_ROOT"/landing-zone/*/ "$REPO_ROOT"/demo/*/ "$REPO_ROOT"/demo/*/*/; do
  # Chi tinh thu muc that su co code Terraform
  ls "$d"*.tf >/dev/null 2>&1 || continue
  layer="${d#"$REPO_ROOT"/}"
  layer="${layer%/}"
  # Bo qua demo co y dung state local
  case " $(echo $LOCAL_STATE_LAYERS) " in *" $layer "*) continue ;; esac
  if ! echo "$configs" | jq -e --arg k "$layer" 'has($k)' >/dev/null 2>&1; then
    missing="${missing}${layer}"$'\n'
    n_missing=$((n_missing + 1))
  fi
done

if [ "$n_missing" -gt 0 ]; then
  echo
  amber "CO $n_missing LAYER TREN DIA MA KHONG CO TRONG STATE:"
  # In nguyen ten, ke ca khi trong ten co dau cach. Dau nhay quanh ten
  # de mot thu muc rac - ten co dau cach, ky tu la - nhin ra ngay la
  # rac chu khong lan vao danh sach layer that.
  printf '%s' "$missing" | while IFS= read -r m; do
    [ -n "$m" ] || continue
    echo "    \"$m\""
  done
  echo
  echo "  backend_hcl la output cua Terraform, va output nam trong state."
  echo "  Them dong vao local.layers (outputs.tf) roi PHAI apply lai:"
  echo
  echo "    terraform apply        # 0 resource doi, chi Outputs"
  echo "    ./wire-backends.sh"
  echo
  echo "  Ten co dau cach hay ky tu la KHONG phai layer thieu khai bao -"
  echo "  do la mot thu muc rac nam trong demo/ hoac landing-zone/."
  echo "  Xem va xoa:  find demo landing-zone -maxdepth 2 -type d"
  echo
fi

[ "$DRY_RUN" = "1" ] && exit 0

echo
echo "Da ghi $written file, bo qua $skipped."
echo
amber "backend.hcl chua ten bucket - KHONG phai bi mat, nhung cung"
amber "khong can commit. Da co trong .gitignore."
echo
########################################
# HAI TRUONG HOP KHAC NHAU - dung nham la mat cong
#
#   Layer DA apply       -> can -migrate-state (chuyen state cu len S3)
#   Layer KHONG co state local -> chi can init. Hai truong hop:
#     chua apply bao gio, HOAC da chuyen len S3 tu truoc.
#
# Phan biet bang su ton tai cua file state local.
########################################

echo "Buoc tiep theo - HAI NHOM khac nhau:"
echo

has_state=""; no_state=""

while read -r layer; do
  [ -d "$REPO_ROOT/$layer" ] || continue
  if [ -f "$REPO_ROOT/$layer/terraform.tfstate" ]; then
    has_state="$has_state$layer"$'\n'
  else
    no_state="$no_state$layer"$'\n'
  fi
done < <(echo "$configs" | jq -r 'keys[]')

if [ -n "$has_state" ]; then
  green "  Da co state local -> CAN chuyen len S3:"
  echo
  while read -r l; do
    [ -z "$l" ] && continue
    echo "    cd $l && terraform init -migrate-state -backend-config=backend.hcl"
  done <<<"$has_state"
  echo
  amber "  Lam TUNG layer mot. Sau moi lan:"
  echo "    terraform state list    # phai con nguyen resource"
  echo "    terraform plan          # PHAI ra \"No changes\""
  echo
  amber "  Ra diff thi DUNG LAI - state chua chuyen du. Dung apply."
  amber "  Chi xoa terraform.tfstate SAU KHI plan da ra \"No changes\"."
  echo
fi

if [ -n "$no_state" ]; then
  grey "  Khong co state local de chuyen (chua apply, hoac da chuyen roi):"
  echo
  while read -r l; do
    [ -z "$l" ] && continue
    echo "    cd $l && terraform init -backend-config=backend.hcl"
  done <<<"$no_state"
  echo
  grey "  Khong dung -migrate-state cho nhom nay."
fi
