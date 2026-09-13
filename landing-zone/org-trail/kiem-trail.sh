#!/usr/bin/env bash
#
# Kiem CloudTrail to chuc DANG THAT o AWS - khong doc Terraform state.
#
#   ./kiem-trail.sh
#
# Khong tham so. TU_THU_MUC=<dir> de doc JSON co san (test offline).
#
# PHEP KIEM LOG KHONG O DAY: no chung cho moi pipeline nen nam o
# ../ops-gate/kiem-log.sh, va buildspec-verify.yml goi no LUON sau lenh
# nay.
#
# ======================================================================
# VI SAO CAN, KHI APPLY DA BAO THANH CONG
#
# `UpdateTrail` tra ve 200 khong co nghia la trail con GHI. Mot trail
# ngung ghi khong co trieu chung nao trong console ngoai mot chu, va
# khoang trong no de lai KHONG lay lai duoc - do la ca ly do ton tai cua
# layer nay.
#
# Da xay ra mot lan gan nhu the: pipeline sua tag cua trail, apply xanh,
# va cau hoi "trail con ghi khong" chi duoc tra loi bang mot lenh
# get-trail-status chay bang tay sau do.
#
# ======================================================================
# SAU THUOC TINH, VA CHUNG LA SAU MUC gate.py CANH
#
#   IsLogging                     trail con ghi
#   LatestDeliveryError           lo cuoi co giao duoc
#   IsOrganizationTrail           phu ca to chuc, khong chi management
#   IsMultiRegionTrail            region khac khong thanh vo hinh
#   IncludeGlobalServiceEvents    con thay IAM, STS, CloudFront
#   LogFileValidationEnabled      file log bi sua thi phat hien duoc
#
# Tat bat ky cai nao trong sau cai deu la NOI theo gate.py (muc
# aws_cloudtrail). Nen chung la dung tap phai doc lai o day.
#
# ======================================================================
# LatestDeliveryTime: BAO, KHONG PHAI CHAN
#
# Ban dau toi de KHONG co verify cho pipeline nay, ly do ghi la "phai doi
# ~2 phut cho CloudTrail giao lo dau tien, nen mot verify chay ngay se doc
# dau thoi gian CU va ket luan sai theo chieu an tam".
#
# Ly do do SAI - no de MOT phep do co do tre phu quyet ca buoc verify.
# Nam thuoc tinh con lai tuc thi va doc duoc ngay tu management.
#
# Cach dung cho LatestDeliveryTime la BAO TUOI cua no, va chi CANH BAO
# khi qua cu (mac dinh 60 phut) - khong bao gio bao LOI. Mot lo log chua
# giao sau hai phut la binh thuong; mot lo chua giao sau mot tieng thi
# khong.
#
set -uo pipefail

XANH=$'\033[32m'; DO=$'\033[31m'; VANG=$'\033[33m'; HET=$'\033[0m'

if [[ $# -gt 0 ]]; then
  echo "Script nay khong nhan tham so (nhan duoc: $*)."
  exit 2
fi

D="${TU_THU_MUC:-}"
if [[ -z "$D" ]]; then
  D=$(mktemp -d)
  trap 'rm -rf "$D"' EXIT
  GOI_AWS=yes
else
  GOI_AWS=no
  echo "${VANG}Che do offline${HET}: doc JSON co san tu $D, KHONG goi AWS."
fi

REGION="${AWS_REGION:-ap-southeast-1}"

if [[ "$GOI_AWS" == "yes" ]]; then
  ########################################
  # KHONG DOAN TEN TRAIL
  #
  # describe-trails khong tham so tra ve MOI trail trong region, ke ca
  # trail cua nguoi khac va shadow trail cua trail to chuc o region khac.
  # Loc theo IsOrganizationTrail + HomeRegion de lay dung trail cua LZ -
  # doan ten theo tien to project se hong vi ten that la "quh11-lz-..."
  # chu khong phai "qh11-lz-..." (mot chu u thua trong tfvars, xem loi 123).
  ########################################
  aws cloudtrail describe-trails --region "$REGION" --output json \
    > "$D/trails.json" 2>"$D/trails.err"

  for NAME in $(python3 - "$D/trails.json" "$REGION" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for t in d.get("trailList", []):
    if t.get("IsOrganizationTrail") and t.get("HomeRegion") == sys.argv[2]:
        print(t["Name"])
PY
  ); do
    aws cloudtrail get-trail-status --name "$NAME" --region "$REGION" --output json \
      > "$D/status-$NAME.json" 2>"$D/status-$NAME.err"
  done
fi

########################################
# PHAN TICH
########################################
python3 - "$D" "$REGION" <<'PY'
import glob, json, os, sys
from datetime import datetime, timezone

D, REGION = sys.argv[1], sys.argv[2]
XANH, DO, VANG, HET = "\033[32m", "\033[31m", "\033[33m", "\033[0m"
loi, canh = [], []

# Qua con so nay thi CANH BAO. Khong phai LOI: CloudTrail giao theo lo va
# lo co the tha den vai chuc phut khi khong co hoat dong nao.
TRE_PHUT = int(os.environ.get("TRE_PHUT", "60"))


def doc(ten):
    """Tra ve (du_lieu, thong_bao_loi). PHAI tra ve ca hai - "rong",
    "AWS bao loi" va "JSON hong" la ba viec khac nhau."""
    p = os.path.join(D, ten)
    err = ""
    pe = p.rsplit(".json", 1)[0] + ".err"
    if os.path.exists(pe):
        err = open(pe).read().strip()
    if not os.path.exists(p) or os.path.getsize(p) == 0:
        return None, err or f"khong co file {ten}"
    try:
        return json.load(open(p)), ""
    except Exception as e:
        return None, err or f"{ten} khong phai JSON: {e}"


print()
print("── CloudTrail to chuc")

d, e = doc("trails.json")
if d is None:
    print(f"  {DO}LOI{HET}  khong doc duoc describe-trails.")
    print(f"        {e}")
    print("        Day KHONG phai 'khong co trail nao'.")
    sys.exit(1)

trails = [
    t for t in (d.get("trailList") or [])
    if t.get("IsOrganizationTrail") and t.get("HomeRegion") == REGION
]

if not trails:
    tong = len(d.get("trailList") or [])
    print(f"  {DO}LOI{HET}  KHONG co trail to chuc nao o home region {REGION}.")
    print(f"        describe-trails doc duoc {tong} trail, khong cai nao co")
    print("        IsOrganizationTrail = true. Doc duoc va rong - nen day KHONG")
    print("        phai loi doc: trail chua duoc tao, hoac no la trail mot account.")
    sys.exit(1)

####################################
# NHIEU TRAIL TO CHUC LA MOT CAU HOI, KHONG PHAI MOT LOI
#
# Hai trail to chuc cung ghi thi khong mat log - chi ton tien doi. Nhung
# no cung co nghia la mot cai trong so do KHONG do Terraform quan, va thu
# do se khong xuat hien o bat ky ban plan nao.
####################################
if len(trails) > 1:
    canh.append(
        f"co {len(trails)} trail to chuc o {REGION}: "
        + ", ".join(t["Name"] for t in trails)
        + ". Khong mat log, nhung mot trong so do co the KHONG do Terraform"
        " quan - va thu do khong xuat hien o ban plan nao."
    )

# Sau thuoc tinh, va chung la sau muc gate.py canh (muc aws_cloudtrail).
BAT_BUOC = (
    ("IsOrganizationTrail", "phu ca to chuc; false = chi ghi management account, tuc vung mu lon nhat"),
    ("IsMultiRegionTrail", "hoat dong o region khac thanh vo hinh"),
    ("IncludeGlobalServiceEvents", "mat su kien IAM, STS, CloudFront - dung nhung thu de leo quyen"),
    ("LogFileValidationEnabled", "file log bi sua khong phat hien duoc; ban ghi con do nhung khong con lam bang chung"),
)

for t in trails:
    ten = t["Name"]
    print(f"    {XANH}v{HET} {ten}")
    print(f"      bucket: {t.get('S3BucketName') or '(khong co)'}")

    for khoa, vi_sao in BAT_BUOC:
        if t.get(khoa):
            print(f"      {khoa:<28} true")
        else:
            loi.append(f"{ten}: {khoa} = {t.get(khoa)!r}. {vi_sao}.")

    ####################################
    # IsLogging - THUOC TINH QUAN TRONG NHAT, VA NO O API KHAC
    #
    # describe-trails KHONG tra ve no. Mot script chi doc describe-trails
    # se bao "trail day du" cho mot trail da ngung ghi tu hai thang truoc.
    ####################################
    st, e = doc(f"status-{ten}.json")
    if st is None:
        loi.append(
            f"{ten}: khong doc duoc get-trail-status.\n"
            f"        {e}\n"
            "        Day la thuoc tinh QUAN TRONG NHAT (IsLogging) va no o mot API\n"
            "        KHAC describe-trails - khong doc duoc nghia la khong biet trail\n"
            "        con ghi hay khong."
        )
        continue

    if st.get("IsLogging"):
        print(f"      {'IsLogging':<28} true")
    else:
        loi.append(
            f"{ten}: IsLogging = {st.get('IsLogging')!r} - TRAIL KHONG GHI.\n"
            "        Khoang trong tu luc ngung den luc bat lai KHONG lay lai duoc,\n"
            "        ke ca sau khi da sua. Bat lai: aws cloudtrail start-logging."
        )

    for khoa in ("LatestDeliveryError", "LatestNotificationError", "LatestDigestDeliveryError"):
        if st.get(khoa):
            loi.append(f"{ten}: {khoa} = {st[khoa]!r}. Lo log gan nhat KHONG giao duoc.")

    ####################################
    # LatestDeliveryTime - BAO TUOI, KHONG CHAN
    ####################################
    dt = st.get("LatestDeliveryTime")
    if not dt:
        canh.append(
            f"{ten}: chua co LatestDeliveryTime.\n"
            "        Binh thuong voi mot trail vua tao (lo dau mat ~15 phut). Voi mot\n"
            "        trail da chay lau thi khong - kiem bucket policy."
        )
    else:
        try:
            # boto tra ve chuoi ISO co offset khi --output json
            t0 = datetime.fromisoformat(str(dt).replace("Z", "+00:00"))
            tuoi = (datetime.now(timezone.utc) - t0).total_seconds() / 60
            print(f"      {'LatestDeliveryTime':<28} {t0.isoformat()}  ({tuoi:.0f} phut truoc)")
            if tuoi > TRE_PHUT:
                canh.append(
                    f"{ten}: lo log gan nhat cach day {tuoi:.0f} phut (nguong {TRE_PHUT}).\n"
                    "        CloudTrail giao theo lo nen vai phut la binh thuong; mot tieng\n"
                    "        thi khong. Khong bao LOI vi mot to chuc it hoat dong co the\n"
                    "        that su khong co gi de giao."
                )
        except Exception as ex:
            canh.append(f"{ten}: khong doc duoc LatestDeliveryTime {dt!r}: {ex}")

print()
for c in canh:
    print(f"  {VANG}CANH BAO{HET} {c}")
for l in loi:
    print(f"  {DO}LOI{HET}  {l}")

print()
print(f"  Da kiem: {len(trails)} trail to chuc, sau thuoc tinh moi cai.")
if loi:
    print(f"  {DO}{len(loi)} loi{HET}, {len(canh)} canh bao.")
    sys.exit(1)
if canh:
    print(f"  {VANG}{len(canh)} canh bao{HET}, 0 loi.")
    sys.exit(0)
print(f"  {XANH}Trail dang ghi, day du sau thuoc tinh.{HET} 0 canh bao.")
PY
