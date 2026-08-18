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
set -euo pipefail

cd "$(dirname "$0")"

# Gioi han kich thuoc inline policy cua permission set.
# KIEM CHUNG lai trong Service Quotas neu AWS co thay doi.
MAX_BYTES=${MAX_BYTES:-32768}
WARN_BYTES=$((MAX_BYTES / 2))

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
amber() { printf '\033[33m%s\033[0m\n' "$*"; }

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Thieu $cmd"; exit 1; }
done

if [ ! -d .terraform ]; then
  red "Chua chay terraform init."
  echo "  terraform init"
  exit 1
fi

echo "Danh sach permission set..."
sets=$(terraform console <<<'keys(local.permission_sets)' \
       | tr -d '[]",' | tr ' ' '\n' | sed '/^$/d')

if [ -z "$sets" ]; then
  red "Khong doc duoc local.permission_sets"
  exit 1
fi

fail=0
total=0

printf '\n%-24s %8s  %s\n' "PERMISSION SET" "BYTES" "KET QUA"
printf -- '-%.0s' {1..60}; echo

while read -r ps; do
  [ -z "$ps" ] && continue
  total=$((total + 1))

  stmt_names=$(terraform console <<<"local.permission_sets[\"$ps\"].statements" \
               | tr -d '[]",' | tr ' ' '\n' | sed '/^$/d')

  if [ -z "$stmt_names" ]; then
    printf '%-24s %8s  %s\n' "$ps" "-" "chi dung managed policy"
    continue
  fi

  # Rap y het cach permission-sets.tf lam
  body=""
  while read -r n; do
    [ -z "$n" ] && continue
    frag=$(terraform console <<<"local.stmt[\"$n\"]" | sed 's/^"//; s/"$//' \
           | sed 's/\\"/"/g')
    [ -z "$frag" ] && continue
    if [ -z "$body" ]; then body="$frag"; else body="$body,$frag"; fi
  done <<<"$stmt_names"

  policy="{\"Version\":\"2012-10-17\",\"Statement\":[$body]}"
  bytes=${#policy}

  status=""

  if ! echo "$policy" | jq empty >/dev/null 2>&1; then
    status="JSON KHONG HOP LE"
    fail=1
  elif echo "$policy" | jq -e '.. | nulls' >/dev/null 2>&1; then
    status="co gia tri null"
    fail=1
  elif [ "$bytes" -gt "$MAX_BYTES" ]; then
    status="VUOT GIOI HAN $MAX_BYTES"
    fail=1
  elif [ "$bytes" -gt "$WARN_BYTES" ]; then
    status="gan giới hạn"
  else
    # Moi statement phai co Effect
    missing=$(echo "$policy" | jq '[.Statement[] | select(has("Effect") | not)] | length')
    if [ "$missing" != "0" ]; then
      status="co statement thieu Effect"
      fail=1
    else
      status="ok"
    fi
  fi

  case "$status" in
    ok)               printf '%-24s %8s  ' "$ps" "$bytes"; green "$status" ;;
    "gan giới hạn")   printf '%-24s %8s  ' "$ps" "$bytes"; amber "$status" ;;
    *)                printf '%-24s %8s  ' "$ps" "$bytes"; red "$status" ;;
  esac
done <<<"$sets"

echo
echo "Da kiem tra $total permission set."

if [ "$fail" -ne 0 ]; then
  red "CO LOI - khong apply."
  exit 1
fi

green "Tat ca policy hop le."
