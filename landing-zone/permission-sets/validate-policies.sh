#!/usr/bin/env bash
#
# Kiem tra cac inline policy duoc rap tu chuoi JSON trong
# permission-sets.tf: co dung JSON khong, co qua gioi han kich thuoc
# khong, co lot khoa null nao khong.
#
# Vi sao can: permission-sets.tf rap policy bang join() chuoi thay vi
# jsonencode ca list (Terraform khong ghep duoc list object khac bo
# thuoc tinh). Danh doi la trinh bien dich khong con bat loi JSON ho
# minh nua - script nay lam viec do.
#
# CAN: terraform init da chay xong (can tai provider tu registry).
#
#   ./validate-policies.sh
#
# Bien moi truong:
#   MAX_BYTES  gioi han inline policy (mac dinh 32768)
#   TF_ARGS    tham so them cho terraform console, vi du:
#              TF_ARGS="-var enforce_security_admin_boundary=true" ./validate-policies.sh
#
set -euo pipefail

cd "$(dirname "$0")"

# Gioi han kich thuoc inline policy cua permission set.
# KIEM CHUNG lai trong Service Quotas neu AWS co thay doi.
MAX_BYTES=${MAX_BYTES:-32768}
WARN_BYTES=$((MAX_BYTES / 2))
TF_ARGS=${TF_ARGS:-}

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    red "Thieu $cmd"
    exit 1
  }
done

if [ ! -d .terraform ]; then
  red "Chua chay terraform init."
  echo "  terraform init -backend-config=backend.hcl"
  exit 1
fi

########################################
# MOT lan goi terraform console cho tat ca
#
# Ban truoc goi console mot lan cho MOI statement cua MOI set -
# khoang 100 lan, moi lan vai giay. Te hon: ket qua duoc gan bang
#   sets=$(terraform console ... | tr ... | sed ...)
# Ma thoat cua pipeline la ma thoat cua sed, LUON bang 0, nen
# set -e khong bao gio kich hoat va loi cua terraform loi qua -
# script in tiep mot bang rong roi thoat 0 nhu khong co gi.
#
# Bay gio: mot lan goi, bat stderr, kiem tra ma thoat tuong minh.
########################################

echo "Danh sach permission set..."

# HAI RANG BUOC CUNG LUC, phai thoa ca hai:
#
#   1. terraform console phi tuong tac danh gia TUNG DONG mot.
#      Bieu thuc xuong dong -> "Missing expression".
#   2. HCL can newline HOAC dau phay giua cac thuoc tinh cua object.
#      Ep ve mot dong ma khong co phay -> "Missing attribute separator".
#
# Nen: viet nhieu dong cho de doc, CO dau phay sau moi thuoc tinh,
# roi ep ve mot dong bang tr truoc khi dua vao console.
EXPR_READABLE='jsonencode({
  for k, v in local.permission_sets : k => {
    scope      = v.scope,
    session    = v.session_duration,
    managed    = length(v.managed),
    statements = v.statements,
    policy     = length(v.statements) == 0 ? "" : format(
      "{\"Version\":\"2012-10-17\",\"Statement\":[%s]}",
      join(",", [for n in v.statements : local.stmt[n]])
    ),
  }
})'

EXPR=$(printf '%s' "$EXPR_READABLE" | tr '\n' ' ')

tf_err=$(mktemp)
trap 'rm -f "$tf_err"' EXIT

########################################
# In loi cua Terraform cho de doc
#
# BAY PHAI BIET: khi variable validation that bai trong
# `terraform console` che do pipe, Terraform van di tiep va danh gia
# bieu thuc, roi PANIC:
#
#   panic: value for local.stmt was requested before it was provided
#   !!!!!! TERRAFORM CRASH !!!!!!
#   Terraform crashed! This is always indicative of a bug within Terraform.
#
# Cai banner do TO HON han loi that o phia tren va noi sai huong -
# nguoi doc se di bao bug Terraform thay vi sua terraform.tfvars.
#
# Nen: cat bo phan stack trace, giu loi that, va noi ro panic la he
# qua chu khong phai nguyen nhan.
########################################
print_tf_error() {
  # Moi thu TRUOC banner crash moi la loi that
  sed '/TERRAFORM CRASH/,$d' "$tf_err" | sed '/^$/{N;/^\n$/D;}' >&2

  if grep -q 'TERRAFORM CRASH\|^panic:' "$tf_err"; then
    echo >&2
    amber "Da cat bo phan stack trace cua Terraform." >&2
    amber "Panic la HE QUA cua loi o tren, khong phai nguyen nhan:" >&2
    amber "console che do pipe van danh gia bieu thuc sau khi variable" >&2
    amber "validation that bai. Sua loi o tren la het - khong phai di" >&2
    amber "bao bug cho Terraform." >&2
    echo >&2
    echo "Xem nguyen van: terraform console < /dev/null" >&2
  fi
}

# shellcheck disable=SC2086
if ! raw=$(printf '%s\n' "$EXPR" | terraform console $TF_ARGS 2>"$tf_err"); then
  red "terraform console that bai - KHONG kiem tra duoc gi."
  echo

  # Goi y cu the cho loi hay gap nhat: tfvars chep tu ban example cu
  if grep -q 'Chi chap nhan hai khoa' "$tf_err"; then
    amber "terraform.tfvars nhieu kha nang duoc chep tu ban example cu."
    amber "Sua lai thanh dung hai khoa:"
    echo
    echo '  passrole_prefixes = {'
    echo '    workload  = "lz-workload-"'
    echo '    analytics = "lz-analytics-"'
    echo '  }'
    echo
  fi

  print_tf_error
  exit 1
fi

# Loi kieu du lieu trong locals van co the tra ve ma thoat 0 kem
# stdout rong. Bat luon truong hop do.
if ! data=$(printf '%s' "$raw" | jq -r . 2>/dev/null) || [ -z "$data" ]; then
  red "Khong doc duoc ket qua tu terraform console."
  echo
  print_tf_error
  echo "--- stdout ---" >&2
  printf '%s\n' "$raw" >&2
  exit 1
fi

total=$(printf '%s' "$data" | jq 'keys | length')
if [ "$total" -eq 0 ]; then
  red "local.permission_sets rong."
  exit 1
fi

fail=0

printf '\n%-24s %8s %5s  %s\n' "PERMISSION SET" "BYTES" "STMT" "KET QUA"
printf -- '-%.0s' {1..64}
echo

while read -r ps; do
  policy=$(printf '%s' "$data" | jq -r --arg k "$ps" '.[$k].policy')

  if [ -z "$policy" ]; then
    printf '%-24s %8s %5s  %s\n' "$ps" "-" "0" "chi dung managed policy"
    continue
  fi

  bytes=${#policy}
  nstmt=$(printf '%s' "$policy" | jq '.Statement | length' 2>/dev/null || echo "-")
  status=""

  if ! printf '%s' "$policy" | jq empty >/dev/null 2>&1; then
    status="JSON KHONG HOP LE"
    fail=1
  elif printf '%s' "$policy" | jq -e '.. | nulls' >/dev/null 2>&1; then
    status="co gia tri null"
    fail=1
  elif [ "$bytes" -gt "$MAX_BYTES" ]; then
    status="VUOT GIOI HAN $MAX_BYTES"
    fail=1
  elif [ "$(printf '%s' "$policy" | jq '[.Statement[] | select(has("Effect") | not)] | length')" != "0" ]; then
    status="co statement thieu Effect"
    fail=1
  elif [ "$(printf '%s' "$policy" | jq '[.Statement[].Sid] | length as $n | unique | length as $u | $n - $u')" != "0" ]; then
    # Sid trung nhau trong mot policy = AWS tu choi ca policy.
    # Rat de xay ra khi mot set vo tinh liet ke hai lan cung mot manh.
    status="TRUNG Sid"
    fail=1
  elif [ "$bytes" -gt "$WARN_BYTES" ]; then
    status="gan gioi han"
  else
    status="ok"
  fi

  case "$status" in
    ok)
      printf '%-24s %8s %5s  ' "$ps" "$bytes" "$nstmt"
      green "$status"
      ;;
    "gan gioi han")
      printf '%-24s %8s %5s  ' "$ps" "$bytes" "$nstmt"
      amber "$status"
      ;;
    *)
      printf '%-24s %8s %5s  ' "$ps" "$bytes" "$nstmt"
      red "$status"
      ;;
  esac
done < <(printf '%s' "$data" | jq -r 'keys[]')

echo
echo "Da kiem tra $total permission set."

########################################
# Canh bao pham vi rong
#
# Khong phai loi - nhung set khong co account nao thi im lang khong
# tao assignment, va nguoi ta tuong da cap quyen roi.
########################################

empty_scope=$(printf '%s' "$data" | jq -r '[to_entries[] | select(.value.scope == "none") | .key] | join(", ")')
[ -n "$empty_scope" ] && amber "Khong gan tu dong (scope=none): $empty_scope"

if [ "$fail" -ne 0 ]; then
  echo
  red "CO LOI - khong apply."
  exit 1
fi

echo
green "Tat ca policy hop le."
echo
echo "Kiem tra luon nhanh bat boundary (khac biet duy nhat la lz-security-admin):"
echo "  TF_ARGS=\"-var enforce_security_admin_boundary=true\" ./validate-policies.sh"
