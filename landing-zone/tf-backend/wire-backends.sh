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

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { red "Thieu $cmd"; exit 1; }
done

if [ ! -f terraform.tfstate ] && [ ! -d .terraform ]; then
  red "Chua apply tf-backend."
  echo "  terraform init && terraform apply"
  exit 1
fi

echo "Doc output tu tf-backend..."
if ! configs=$(terraform output -json backend_hcl 2>/dev/null); then
  red "Khong doc duoc output backend_hcl. Da apply chua?"
  exit 1
fi

if [ "$(echo "$configs" | jq 'length')" = "0" ]; then
  red "Output rong."
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
  written=$((written + 1))
done < <(echo "$configs" | jq -r 'keys[]')

[ "$DRY_RUN" = "1" ] && exit 0

echo
echo "Da ghi $written file, bo qua $skipped."
echo
amber "backend.hcl chua ten bucket - KHONG phai bi mat, nhung cung"
amber "khong can commit. Da co trong .gitignore."
echo
echo "Buoc tiep theo, lam TUNG layer mot va doc ky truoc khi dong y:"
echo
while read -r layer; do
  [ -d "$REPO_ROOT/$layer" ] || continue
  echo "  cd $layer && terraform init -migrate-state -backend-config=backend.hcl"
done < <(echo "$configs" | jq -r 'keys[]')
echo
echo "Sau moi lan: terraform state list   (phai con nguyen resource)"
