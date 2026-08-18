#!/usr/bin/env bash
#
# Chay terraform init + validate + plan cho MOI layer thuong truc,
# in ra bang tom tat.
#
# Dung de doi chieu hai ban organization (DIY) va control-tower
# ma KHONG TAO GI CA - plan khong cham vao ha tang.
#
#   ./plan-all.sh                chay tat ca
#   ./plan-all.sh organization   chi mot layer
#   ./plan-all.sh --no-plan      chi init + validate (khong can credential)
#
# CAN: credential cua MANAGEMENT ACCOUNT cho buoc plan.
# Buoc validate thi khong can credential.
#
set -uo pipefail

cd "$(dirname "$0")"

LAYERS=(tf-backend organization control-tower config-detective billing-guard permission-sets)

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }
grey()  { printf '\033[90m%s\033[0m' "$*"; }

NO_PLAN=0
TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --no-plan) NO_PLAN=1 ;;
    -*)        echo "Khong hieu tham so: $arg"; exit 1 ;;
    *)         TARGETS+=("$arg") ;;
  esac
done

[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${LAYERS[@]}")

command -v terraform >/dev/null 2>&1 || { red "Thieu terraform"; echo; exit 1; }

echo
printf '%-20s %-10s %-10s %s\n' "LAYER" "INIT" "VALIDATE" "PLAN"
printf -- '-%.0s' {1..64}; echo

declare -a summary
overall=0

for layer in "${TARGETS[@]}"; do
  if [ ! -d "$layer" ]; then
    printf '%-20s ' "$layer"; amber "khong co thu muc"; echo
    continue
  fi

  printf '%-20s ' "$layer"

  # ---- init ----
  if out=$(cd "$layer" && terraform init -backend=false -input=false -no-color 2>&1); then
    printf '%-19s' "$(green ok)"
  else
    printf '%-19s' "$(red loi)"
    echo
    summary+=("$layer INIT: $(echo "$out" | grep -iE '^(error|│ *error)' | head -3)")
    overall=1
    continue
  fi

  # ---- validate ----
  if out=$(cd "$layer" && terraform validate -no-color 2>&1); then
    printf '%-19s' "$(green ok)"
  else
    printf '%-19s' "$(red loi)"
    echo
    summary+=("$layer VALIDATE: $(echo "$out" | head -8)")
    overall=1
    continue
  fi

  # ---- plan ----
  if [ "$NO_PLAN" = "1" ]; then
    grey "bo qua"; echo
    continue
  fi

  if [ ! -f "$layer/terraform.tfvars" ]; then
    amber "thieu terraform.tfvars"; echo
    continue
  fi

  out=$(cd "$layer" && terraform plan -input=false -no-color -lock=false 2>&1)
  rc=$?

  if [ $rc -ne 0 ]; then
    red "loi"; echo
    summary+=("$layer PLAN: $(echo "$out" | grep -A3 -iE '^│ *error' | head -10)")
    overall=1
    continue
  fi

  if echo "$out" | grep -q "No changes"; then
    green "khong doi"
  else
    counts=$(echo "$out" | grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' | tail -1)
    echo -n "${counts:-co thay doi}"
  fi
  echo
done

if [ ${#summary[@]} -gt 0 ]; then
  echo
  printf -- '-%.0s' {1..64}; echo
  red "CHI TIET LOI"; echo
  for s in "${summary[@]}"; do
    echo
    echo "$s"
  done
fi

echo
if [ "$overall" -eq 0 ]; then
  green "Tat ca layer hop le."
else
  red "Co layer loi - xem chi tiet o tren."
fi
echo

exit $overall
