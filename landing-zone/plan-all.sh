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

LAYERS=(tf-backend organization control-tower config-detective billing-guard permission-sets org-trail account-baseline network)

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
amber() { printf '\033[33m%s\033[0m' "$*"; }
grey()  { printf '\033[90m%s\033[0m' "$*"; }

NO_PLAN=0
TARGETS=""
n_targets=0

# LUU Y BASH 3.2 (ban mac dinh cua macOS): voi set -u, "$@" rong va
# ${#arr[@]} tren mang rong deu nem "unbound variable". Nen dung
# while/shift va dem tay thay vi for-in va ${#...[@]}.
while [ $# -gt 0 ]; do
  case "$1" in
    --no-plan) NO_PLAN=1 ;;
    -*)
      echo "Khong hieu tham so: $1"
      exit 1
      ;;
    *)
      TARGETS="$TARGETS $1"
      n_targets=$((n_targets + 1))
      ;;
  esac
  shift
done

[ "$n_targets" -eq 0 ] && TARGETS="${LAYERS[*]}"

command -v terraform >/dev/null 2>&1 || {
  red "Thieu terraform"
  echo
  exit 1
}

echo
printf '%-20s %-10s %-10s %s\n' "LAYER" "INIT" "VALIDATE" "PLAN"
printf -- '-%.0s' {1..64}
echo

summary=""
n_summary=0
overall=0

for layer in $TARGETS; do
  if [ ! -d "$layer" ]; then
    printf '%-20s ' "$layer"
    amber "khong co thu muc"
    echo
    continue
  fi

  printf '%-20s ' "$layer"

  ####################################
  # init - backend hay khong tuy che do
  #
  # -backend=false BO QUA backend hoan toan. Dung cho --no-plan
  # (chi validate cu phap, khong can credential).
  #
  # NHUNG dung no roi van chay plan la SAI NGUY HIEM: tren mot clone
  # moi, hoac sau khi xoa .terraform, plan se doc STATE LOCAL RONG va
  # bao "Plan: N to add" cho moi thu. Doc nham thanh drift, trong khi
  # thuc te chi la script nhin sai cho.
  #
  # Nen khi CO chay plan: init voi backend.hcl neu co.
  ####################################
  if [ "$NO_PLAN" = "1" ] || [ ! -f "$layer/backend.hcl" ]; then
    init_args="-backend=false"
  else
    init_args="-backend-config=backend.hcl"
  fi

  # shellcheck disable=SC2086
  if out=$(cd "$layer" && terraform init $init_args -input=false -no-color 2>&1); then
    printf '%-19s' "$(green ok)"
  else
    printf '%-19s' "$(red loi)"
    echo
    summary="$summary
$layer INIT: $(echo "$out" | grep -iE '^(error|│ *error)' | head -3)"
    n_summary=$((n_summary + 1))
    overall=1
    continue
  fi

  # ---- validate ----
  if out=$(cd "$layer" && terraform validate -no-color 2>&1); then
    printf '%-19s' "$(green ok)"
  else
    printf '%-19s' "$(red loi)"
    echo
    summary="$summary
$layer VALIDATE: $(echo "$out" | head -8)"
    n_summary=$((n_summary + 1))
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
    red "loi"
    echo
    summary="$summary
$layer PLAN: $(echo "$out" | grep -A3 -iE '^│ *error' | head -10)"
    n_summary=$((n_summary + 1))
    overall=1
    continue
  fi

  if echo "$out" | grep -q "No changes"; then
    green "khong doi"

  # Plan chi doi OUTPUT thi Terraform KHONG in dong "Plan: N to add..."
  # ma in "without changing any real infrastructure". Khong bat rieng
  # thi no roi vao nhanh mac dinh "co thay doi" - dung ve ky thuat
  # nhung vo ich, vi khong phan biet duoc voi "sap xoa 8 resource".
  elif echo "$out" | grep -q "without changing any real infrastructure"; then
    amber "chi output doi - apply de dong bo"

  else
    counts=$(echo "$out" | grep -oE 'Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy' | tail -1)
    echo -n "${counts:-co thay doi (khong doc duoc so luong - chay terraform plan trong thu muc do)}"

    # Layer da tung apply ma bong nhien "chi them, khong xoa" thuong
    # KHONG phai drift - la plan doc nham state rong.
    if [ -f "$layer/backend.hcl" ] && echo "$counts" | grep -q '0 to change, 0 to destroy'; then
      nstate=$(cd "$layer" && terraform state list 2>/dev/null | grep -c . || echo 0)
      [ "$nstate" = "0" ] && printf '  %s' "$(amber '<- state RONG, xem ghi chu cuoi')"
    fi
  fi
  echo
done

if [ "$n_summary" -gt 0 ]; then
  echo
  printf -- '-%.0s' {1..64}
  echo
  red "CHI TIET LOI"
  echo
  echo "$summary"
fi

echo
if [ "$overall" -eq 0 ]; then
  green "Tat ca layer hop le."
else
  red "Co layer loi - xem chi tiet o tren."
fi
echo
echo
grey "Doc ket qua:"
echo
grey "  khong doi              dung y muon - code khop voi thuc te"
echo
grey "  thieu terraform.tfvars layer chua dung den"
echo
grey "  chi output doi         khong resource nao thay doi - thuong la sua"
echo
grey "                         mo ta output. Apply de state khop lai."
echo
grey "  Plan: N to add ...     layer chua apply, HOAC plan doc nham state rong"
echo
grey "  <- state RONG          layer co backend.hcl ma state khong co gi:"
echo
grey "                         chay 'terraform init -backend-config=backend.hcl'"
echo
grey "                         trong thu muc do roi thu lai. KHONG phai drift."
echo

exit $overall
