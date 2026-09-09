#!/usr/bin/env bash
#
# DOC LOG THAT CUA MOT STAGE TRONG PIPELINE VENDING
#
#   ./log.sh                     stage dang hong (tu tim)
#   ./log.sh E_config_detective  mot stage cu the
#   ./log.sh E_config_detective Apply
#   ./log.sh -a                  ca log, khong loc
#
# ---------------------------------------------------------------
# VI SAO CAN SCRIPT NAY
#
# Khi mot lenh hong, CodeBuild in ra CA KHOI LENH chu khong phai dong
# lenh. Khoi cua buildspec nay chua ca `terraform plan` lan
# `terraform apply`, nen mot loi bat ky deu hien ra duoi hinh dang
# mot loi cua Terraform - va thong bao trong CodePipeline console
# chi co dung khoi do.
#
# Ba cai bay da mat thoi gian, script nay tranh ca ba:
#
#   1. `aws logs tail` gop NHIEU build vao mot dong thoi gian. Ba
#      build trong 70 giay xen ke nhau doc nhu mot build.
#      -> Doc DUNG log stream cua build hong, lay tu CodePipeline.
#
#   2. `--query 'events[].message' --output text` noi cac phan tu
#      bang TAB, khong phai xuong dong. Ca log thanh mot dong, va moi
#      grep/sed neo `^` deu tra ve rong.
#      -> `tr '\t' '\n'`.
#
#   3. Loc theo tu khoa ('Error', 'PLAN HONG') dinh ca dong SCRIPT in
#      lai, vi trong script co nhung tu do.
#      -> Cat theo hai moc `== plan` va `PLAN HONG`.
#
# bash, khong phai zsh.
#
set -euo pipefail
export AWS_PAGER=""

cd "$(dirname "$0")"

REGION=$(terraform output -raw region 2>/dev/null || echo "ap-southeast-1")
PIPELINE=$(terraform output -raw pipeline_name 2>/dev/null || true)
if [ -z "$PIPELINE" ]; then
  echo "LOI: khong doc duoc output pipeline_name."
  echo "     Chay script nay o landing-zone/vending-pipeline, sau khi apply."
  exit 1
fi

NHOM="/aws/codebuild/${PIPELINE}"

########################################
# LAM PHANG TRUOC, LOC SAU
#
# `stageStates[?...].actionStates[?...].latestExecution.field | [0][0]`
# tra ve None: hai phep chieu long nhau bi xep lai, va [0][0] cat vao
# mot cau truc khac voi cau truc minh tuong.
#
# `actionStates[]` lam phang truoc, roi `| [?...]` loc tren mot danh
# sach phang, roi `| [0]` lay phan tu dau. Dai hon mot chut va doc
# duoc - va no tra ve gia tri.
#
# Da mat mot vong vi cho nay, nen tach thanh ham de hai lenh duoi
# khong the lech nhau.
########################################
jq_stage() {
  printf "stageStates[?stageName=='%s'].actionStates[] | %s" "$1" "$2"
}

TAT_CA="no"
if [ "${1:-}" = "-a" ]; then
  TAT_CA="yes"
  shift
fi

STAGE="${1:-}"
ACTION="${2:-}"

########################################
# Tim build hong, neu khong duoc chi dinh
########################################
if [ -z "$STAGE" ]; then
  STAGE=$(aws codepipeline get-pipeline-state --region "$REGION" --name "$PIPELINE" \
    --query 'stageStates[?latestExecution.status==`Failed`].stageName | [0]' --output text)
  if [ -z "$STAGE" ] || [ "$STAGE" = "None" ]; then
    echo "Khong co stage nao o trang thai Failed."
    echo "Chi dinh ten stage neu ban muon doc mot stage da xanh:"
    aws codepipeline get-pipeline --region "$REGION" --name "$PIPELINE" \
      --query 'pipeline.stages[].name' --output text | tr '\t' '\n' | sed 's/^/  /'
    exit 0
  fi
  echo "Stage dang hong: $STAGE"
fi

if [ -z "$ACTION" ]; then
  ACTION=$(aws codepipeline get-pipeline-state --region "$REGION" --name "$PIPELINE" \
    --query "$(jq_stage "$STAGE" "[?latestExecution.status=='Failed'] | [0].actionName")" \
    --output text)
  # if/fi chu khong phai `A || B && C`: chuoi do doc la (A || B) && C,
  # nen khi ACTION co gia tri that thi ca bieu thuc tra ve 1 va
  # `set -e` giet script - dung o cho khong co gi sai ca.
  if [ -z "$ACTION" ] || [ "$ACTION" = "None" ]; then
    ACTION="Plan"
  fi
fi

########################################
# externalExecutionId co dang "<ten-project>:<uuid>".
# Ten log stream la phan UUID.
########################################
BUILD=$(aws codepipeline get-pipeline-state --region "$REGION" --name "$PIPELINE" \
  --query "$(jq_stage "$STAGE" "[?actionName=='${ACTION}'] | [0].latestExecution.externalExecutionId")" \
  --output text)

if [ -z "$BUILD" ] || [ "$BUILD" = "None" ]; then
  echo "LOI: action ${STAGE}/${ACTION} chua chay lan nao trong lan thuc thi hien tai."
  exit 1
fi

STREAM="${BUILD##*:}"
echo "── ${STAGE} / ${ACTION}"
echo "── build  : ${BUILD}"
echo "── stream : ${NHOM}/${STREAM}"
echo ""

DONG=$(aws logs get-log-events --region "$REGION" \
  --log-group-name "$NHOM" --log-stream-name "$STREAM" \
  --limit 1000 --no-start-from-head \
  --query 'events[].message' --output text | tr '\t' '\n')

if [ "$TAT_CA" = "yes" ]; then
  printf '%s\n' "$DONG"
  exit 0
fi

# Cat tu `== plan` (hoac `== apply`) toi khi bao hong. Neu khong khop
# moc nao thi in phan dau - luc do loi nam TRUOC buoc plan, thuong la
# o tfvars, backend hoac khoa state.
CAT=$(printf '%s\n' "$DONG" \
  | sed -n '/^== \(plan\|apply\)/,/^\(PLAN HONG\|Apply complete\|LOI:\)/p')

if [ -n "$CAT" ]; then
  printf '%s\n' "$CAT"
else
  echo "(khong thay moc '== plan' - loi xay ra TRUOC buoc plan)"
  echo ""
  printf '%s\n' "$DONG" | sed -n '/^== /,$p' | head -60
fi

echo ""
echo "── ca log: ./log.sh ${STAGE} ${ACTION} -a   (hoac them -a truoc ten stage)"
