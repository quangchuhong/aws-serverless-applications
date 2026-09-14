#!/usr/bin/env python3
"""Kiem khop giua module tf-pipeline va MOI caller cua no.

    ./kiem-module.py                 # tu tim moi caller
    ./kiem-module.py <thu-muc> ...   # chi kiem nhung caller da neu

=========================================================================
VI SAO CAN, KHI DA CO `terraform validate`

validate bat het nhung thu duoi day - nhung no doi provider tai duoc tu
registry.terraform.io. Trong moi truong bi chan mang (va trong mot CI
khong co quyen ra ngoai) thi khong chay duoc, va luc do thu duy nhat con
lai la doc bang mat.

Muoi ba phep kiem, khong can mang:

  1. dung var.X ma khong khai
  2. module khai var khong ai dung
  3. caller truyen input ma module khong co
  4. bien module BAT BUOC ma caller khong truyen
  5. caller doc module.pipeline.X ma module khong xuat
  6. dung local.X ma khong khai
  7. bien module dung type = list(any)
  8. layer doc state cua layer khac ma caller khong khai state_chi_doc
  9. phep 1 va 6 ap ca cho layer KHONG dung module (trigger-filter,
     vending-pipeline, organization, ...) - xem kiem_layer_don()
 10. layer duoc mot pipeline APPLY ma khong duong dan nao trong ban_do
     cua trigger-filter cham toi - xem kiem_phu_layer()
 11. layer duoc mot pipeline APPLY ma push-tfvars.sh khong day tfvars len
     - xem kiem_push_tfvars()
 12. tien to trong ban_do ma pipeline do KHONG apply layer nao duoi no -
     xem kiem_tien_to_co_ich()
 13. CodeBuild project pipeline GOI ma iam.tf khong cap StartBuild -
     xem kiem_project_duoc_phep()

Phep thu 7 la mot bai hoc duoc ma hoa: list(any) buoc MOI phan tu cung
mot type, va IAM statement thi luon khac hinh - mot cai co Condition, cai
khac khong. Thong bao khi vuong noi ve "list", khong noi ve IAM. Loi 117.

=========================================================================
DUONG TINH GIA LA KE THU O DAY

Mot bo kiem hay bao sai se bi bo qua, va luc do no khong bat duoc cai
that. Nen no bo CHU THICH va HEREDOC (van xuoi) truoc khi doc, va GIU
chuoi thuong - noi suy Terraform nam trong chuoi, nen strip chung se lam
moi ${var.x} bien mat.

Doi lai: van xuoi trong chuoi MOT DONG van bi doc thanh tham chieu. Cach
chua khong phai noi bo kiem, ma la viet van xuoi khong mang tien to
`var.` - dung "bien tag_policy_keys" thay vi "var.tag_policy_keys".

=========================================================================
BA LAN CHINH BO KIEM NAY TU SAI, ca ba dung dang khuyet diem cua du an

  chay tu thu muc khac -> glob RONG -> chay 7 phep tren chuoi rong roi
    in "Khop het". Chua: neo duong dan vao goc repo + chot chan 0 file.
  strip ca chuoi thuong -> moi ${var.x} bien mat -> bao "khai khong
    dung" tren 7 bien dang dung.
  bat `locals {` DAU TIEN (o codebuild.tf) -> moi local cua main.tf
    thanh "khong khai". Chua: doc MOI khoi locals.

Va mot lan thu tu, o chinh cho tim caller: ten thu muc duoc viet cung
thanh mot caller duy nhat, nen khi co them bon caller nua thi bo kiem van
in "Khop het" - tren mot caller. Gio no tim theo NOI DUNG (`source` tro
vao modules/tf-pipeline), khong theo ten.
"""

import glob
import os
import re
import sys

GOC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
M = os.path.join(GOC, "modules/tf-pipeline")


def tim_caller():
    """Moi thu muc co file .tf tro vao modules/tf-pipeline."""
    ra = []
    for d in sorted(glob.glob(os.path.join(GOC, "landing-zone/*"))):
        if not os.path.isdir(d):
            continue
        for f in glob.glob(os.path.join(d, "*.tf")):
            # Khop vao `source = ".../modules/tf-pipeline"`, KHONG khop
            # cum tu tran. tf-backend/outputs.tf co nhac ten module trong
            # mot chu thich, va khop van ban tran da keo no vao danh sach
            # caller - lan thu ba trong mot ngay mot phep khop doc trung
            # van xuoi.
            if re.search(r'source\s*=\s*"[^"]*modules/tf-pipeline"', open(f).read()):
                ra.append(d)
                break
    return ra


def boc(t):
    """Bo CHU THICH va HEREDOC. GIU chuoi thuong - xem docstring."""
    t = re.sub(r"#[^\n]*", "", t)
    t = re.sub(r"<<-?EOT.*?\n\s*EOT", '""', t, flags=re.S)
    return t


def doc(d, tru=()):
    return "".join(
        open(f).read()
        for f in sorted(glob.glob(os.path.join(d, "*.tf")))
        if os.path.basename(f) not in tru
    )


def locals_khai(raw):
    """MOI khoi locals, khong chi khoi dau."""
    ra = set()
    for m in re.finditer(r"^locals \{(.*?)^\}", raw, re.S | re.M):
        ra |= set(re.findall(rf"^\s{{2}}({TEN})\s*=", m.group(1), re.M))
    return ra


# TEN CO CHU SO: `[a-z_]+` dung LAI o chu so dau tien.
#
# Khong phai mot phep khop hut - la mot phep khop LECH. Voi `c_ec2 = ...`
# thi mau KHAI doi `\s*=` ngay sau `c_ec`, gap `2`, va khong khop gi ca -
# tuc local do coi nhu khong duoc khai. Con mau DUNG thi `local.c_ec2` van
# ra `c_ec`. Hai ben cat khac nhau, nen ra bon bao sai tren bon ten dang
# dung binh thuong: harden_s3, c_ec2, c_f5, deny_ec2_*.
#
# Duong tinh gia la ke thu o day - xem docstring. Bon cai nay du de mot
# nguoi bat dau bo qua ca bo kiem.
TEN = r"[a-z_][a-z0-9_]*"

khai = lambda t: set(re.findall(rf'variable "({TEN})"', t))
dung = lambda t: set(re.findall(rf"\bvar\.({TEN})", t))
outs = lambda t: set(re.findall(rf'output "({TEN})"', t))
lc = lambda t: set(re.findall(rf"\blocal\.({TEN})", t))


def kiem_module(mt_raw, mt):
    loi = []
    if dung(mt) - khai(mt_raw):
        loi.append(f"module: dung var khong khai: {sorted(dung(mt) - khai(mt_raw))}")
    if khai(mt_raw) - dung(mt):
        loi.append(f"module: khai var khong dung: {sorted(khai(mt_raw) - dung(mt))}")
    if lc(mt) - locals_khai(mt_raw):
        loi.append(f"module: dung local khong khai: {sorted(lc(mt) - locals_khai(mt_raw))}")

    # 7. list(any) - xem docstring.
    for m in re.finditer(rf'variable "({TEN})" \{{(.*?)\n\}}\n', mt_raw, re.S):
        if re.search(r"^\s+type\s*=\s*list\(any\)", m.group(2), re.M):
            loi.append(
                f"module: var.{m.group(1)} dung type = list(any) - buoc moi phan tu "
                "cung mot type. Dung `any` neu cac phan tu khac hinh (IAM statement)."
            )
    return loi


def kiem_caller(C, mt_raw, ten_caller):
    ct_raw = doc(C, tru=("moved.tf",))
    if not ct_raw.strip():
        return [f"{ten_caller}: khong doc duoc file .tf nao. KHONG phai 'khong co gi sai' - la CHUA DOC DUOC."]

    ct = boc(ct_raw)
    loi = []

    if dung(ct) - khai(ct_raw):
        loi.append(f"{ten_caller}: dung var khong khai: {sorted(dung(ct) - khai(ct_raw))}")
    if lc(ct) - locals_khai(ct_raw):
        loi.append(f"{ten_caller}: dung local khong khai: {sorted(lc(ct) - locals_khai(ct_raw))}")

    m = re.search(r'module "pipeline" \{(.*?)\n\}', ct_raw, re.S)
    if not m:
        return loi + [f'{ten_caller}: khong tim thay khoi module "pipeline"']
    truyen = set(re.findall(rf"^\s{{2}}({TEN})\s*=", m.group(1), re.M)) - {"source"}

    if truyen - khai(mt_raw):
        loi.append(f"{ten_caller}: truyen input module khong co: {sorted(truyen - khai(mt_raw))}")

    bat_buoc = {
        x.group(1)
        for x in re.finditer(rf'variable "({TEN})" \{{(.*?)\n\}}\n', mt_raw, re.S)
        if not re.search(r"^\s+default\s*=", x.group(2), re.M)
    }
    if bat_buoc - truyen:
        loi.append(f"{ten_caller}: bien module BAT BUOC ma khong truyen: {sorted(bat_buoc - truyen)}")

    ref = set(re.findall(rf"module\.pipeline\.({TEN})", ct))
    if ref - outs(mt_raw):
        loi.append(f"{ten_caller}: doc output module khong co: {sorted(ref - outs(mt_raw))}")

    # 8. PHU THUOC STATE - phep kiem duy nhat nhin RA NGOAI caller
    #
    # Mot layer co the DOC state cua layer khac qua terraform_remote_state.
    # Khi do khoa state do la mot phan be mat quyen cua pipeline, va
    # layer_keys khong phu duoc (no cap ca quyen GHI).
    #
    # Khong khai thi plan CHET voi:
    #   Error: Unable to access object "<khoa>" ... 403 Forbidden
    # va loi do khong nhac gi toi terraform_remote_state. Da vuong that o
    # pipeline permission-set, phat hien bang mot lan chay chu khong bang
    # suy luan.
    #
    # Phep kiem nay chi bao "layer co doc" - no KHONG doan duoc khoa nao,
    # vi khoa thuong den tu mot bien trong tfvars (vending_state). Nen no
    # la mot canh bao co dia chi, khong phai mot phep so.
    for m2 in re.finditer(r'layer\s*=\s*"([^"]+)"', ct_raw):
        d_layer = os.path.join(GOC, m2.group(1))
        if not os.path.isdir(d_layer):
            continue
        co_remote = any(
            re.search(r'data\s+"terraform_remote_state"', open(f).read())
            for f in glob.glob(os.path.join(d_layer, "*.tf"))
        )
        if co_remote and not re.search(r"state_chi_doc\s*=\s*\[\s*\"", ct_raw):
            loi.append(
                f"{ten_caller}: layer {m2.group(1)} DOC state cua layer khac "
                "(terraform_remote_state) nhung caller khong khai state_chi_doc. "
                "Plan se chet voi mot loi 403 cua S3 khong nhac gi toi remote state."
            )
            break

    return loi


def kiem_layer_don(d, ten):
    """Layer KHONG goi modules/tf-pipeline - chi hai phep kiem tu than.

    Phep 3, 4, 5 va 8 khong ap duoc (khong co khoi module "pipeline"),
    nhung "dung var khong khai" va "dung local khong khai" thi ap cho MOI
    layer. Truoc day chung chi chay tren caller, nen mot layer doc lap
    nhu trigger-filter hay vending-pipeline khong duoc kiem gi ca - va do
    la mot khoang trong im lang, khong phai mot ket luan "khong co gi
    sai".

    KHONG kiem "khai ma khong dung" o day. Layer thuong khai bien de dat
    tu tfvars roi truyen thang xuong, va nhieu layer co bien chi dung
    trong mot nhanh dang tat. Bao cai do se on - va mot bo kiem hay bao
    sai thi khong ai doc nua.
    """
    raw = doc(d)
    if not raw.strip():
        return []
    t = boc(raw)
    loi = []
    if dung(t) - khai(raw):
        loi.append(f"{ten}: dung var khong khai: {sorted(dung(t) - khai(raw))}")
    if lc(t) - locals_khai(raw):
        loi.append(f"{ten}: dung local khong khai: {sorted(lc(t) - locals_khai(raw))}")
    return loi


def tim_layer_don(callers):
    """Moi thu muc landing-zone/* co file .tf ma KHONG phai caller."""
    bo = {os.path.abspath(c.rstrip("/")) for c in callers}
    return [
        d
        for d in sorted(glob.glob(os.path.join(GOC, "landing-zone/*")))
        if os.path.isdir(d)
        and os.path.abspath(d) not in bo
        and glob.glob(os.path.join(d, "*.tf"))
    ]


TF = os.path.join(GOC, "landing-zone/trigger-filter")


def khoi(raw, ten_bien):
    """Than cua `<ten_bien> = [ ... ]` hoac `= { ... }`, DEM NGOAC.

    =====================================================================
    VI SAO DEM NGOAC CHU KHONG REGEX

    Ban dau cho nay dung `(.*?)^[\]}]` - lazy, va doi dau dong cho dau
    dong. No dung cho khoi nhieu dong, va SAI cho khoi mot dong:

        layer_thu_cong = []

    Dau `]` o day khong nam dau dong, nen phep khop chay tiep toi dau
    dong tiep theo co `]` hoac `}` - va nuot ca khoi `tru = { ... }` nam
    sau do. Ket qua: bo kiem bao "layer_thu_cong khai
    ['landing-zone/network/ops/', 'vending']" tren mot danh sach RONG.

    Chinh bo kiem nay bat duoc loi do cua chinh no. Dem ngoac thi khong
    phu thuoc vao viec nguoi ta viet mot dong hay nhieu dong.
    """
    m = re.search(rf"^{ten_bien}\s*=\s*([\[{{])", raw, re.M)
    if not m:
        return ""
    mo = m.group(1)
    dong = {"[": "]", "{": "}"}[mo]
    sau = 0
    for i in range(m.end() - 1, len(raw)):
        if raw[i] == mo:
            sau += 1
        elif raw[i] == dong:
            sau -= 1
            if sau == 0:
                return raw[m.end():i]
    return ""


def danh_sach(raw, ten_bien):
    """Moi chuoi trong `<ten_bien> = [ ... ]` cua mot file tfvars.

    Doc tren van ban DA BOC chu thich, nen dong bi comment khong tinh -
    va do la dieu phai the: mot muc bi comment la mot muc KHONG co hieu
    luc, ke ca khi no van nam do va van doc duoc bang mat.
    """
    return re.findall(r'"([^"]+)"', khoi(raw, ten_bien))


def ban_do_theo_pipeline(raw):
    """`ban_do = { "ten" = [...] }` -> {ten: [tien to]}.

    Doc tren van ban DA BOC chu thich, nen dong bi comment khong tinh.
    """
    than = khoi(raw, "ban_do")
    return {
        k: re.findall(r'"([^"]+)"', v)
        for k, v in re.findall(r'"([^"]+)"\s*=\s*\[(.*?)\]', than, re.S)
    }


def ten_ngan(d, raw_d):
    """Ten NGAN cua pipeline ma thu muc nay dung - cung khoa voi ban_do.

    Caller cua modules/tf-pipeline khai `ten = "..."` TRONG khoi
    module "pipeline". vending-pipeline khong dung module, ten cua no la
    "vending" (local.name = "${var.project}-vending").

    ---------------------------------------------------------------
    PHAI NEO VAO KHOI module, KHONG KHOP `ten =` TRAN

    ops-pipeline/main.tf co HAI dong khop `ten = "..."`:

      dong 159    ten = "SCP (catalog/scp.yaml)"   <- mot muc catalog
      dong 283    ten = "ops"                      <- cai can tim

    Khop tran lay cai DAU TIEN, tuc ban_do["SCP (catalog/scp.yaml)"] -
    khong ton tai - nen layer organization bi bao la khong duoc phu.
    Mot duong tinh gia, va la lan thu ba trong bo kiem nay mot phep khop
    van ban tran bat nham thu khac.
    """
    m = re.search(r'module "pipeline" \{(.*?)\n\}', raw_d, re.S)
    if m:
        t = re.search(r'^\s+ten\s*=\s*"([^"]+)"', m.group(1), re.M)
        if t:
            return t.group(1)
    return "vending" if os.path.basename(d.rstrip("/")) == "vending-pipeline" else os.path.basename(d.rstrip("/"))


def kiem_phu_layer():
    """10. Layer nao duoc pipeline APPLY ma khong duong dan nao cham toi.

    =====================================================================
    VI SAO PHEP KIEM NAY TON TAI

    Sau khi tat rule rieng cua tung pipeline, bo loc trigger-filter la
    duong DUY NHAT den moi pipeline. Luc do mot layer co the roi ra khoi
    he thong theo mot cach khong ai thay:

      pipeline X co mot stage apply layer L
      nhung khong tien to nao trong ban_do cham vao L
      -> thay doi cua L vao main roi NAM DO

    Khong co trieu chung: pipeline van xanh, console van sach, chi la
    khong ai apply L nua. Da xay ra that - thu hep ban do cua vending ve
    account-baseline/ lam landing-zone/network va
    landing-zone/config-detective mat duong tu dong, va khong co gi keu.

    =====================================================================
    RONG LA HOP LE, NHUNG PHAI DUOC KHAI

    Cung loi voi khong_co_lint va khong_co_catalog: layer khong co duong
    tu dong phai nam trong layer_thu_cong. Mot dong trong doc giong het
    mot dong bi quen.

    =====================================================================
    NO DOC FILE NAO

    terraform.tfvars neu co (cau hinh THAT tren may nguoi van hanh),
    khong thi terraform.tfvars.example (ban mau da commit). Phep kiem NOI
    RO no doc cai nao - hai cai co the lech nhau, va doc nham cai nay roi
    ket luan cho cai kia la mot cach bao sai.
    """
    that = os.path.join(TF, "terraform.tfvars")
    mau = os.path.join(TF, "terraform.tfvars.example")
    nguon = that if os.path.exists(that) else mau
    if not os.path.exists(nguon):
        return [
            "trigger-filter: khong co terraform.tfvars lan .example, nen phep kiem "
            "do phu layer KHONG chay. Day KHONG phai 'khong co gi sai'."
        ], None, None

    raw = boc(open(nguon).read())
    thu_cong = set(danh_sach(raw, "layer_thu_cong"))
    ban_do = ban_do_theo_pipeline(raw)

    # Layer nao duoc pipeline nao APPLY. Khoa la ten NGAN cua pipeline -
    # cung khoa voi ban_do.
    ap = {}
    for d in sorted(glob.glob(os.path.join(GOC, "landing-zone/*"))):
        raw_d = "".join(boc(open(f).read()) for f in sorted(glob.glob(os.path.join(d, "*.tf"))))
        L = set(re.findall(r'layer\s*=\s*"(landing-zone/[^"]+)"', raw_d))
        if L:
            ap[ten_ngan(d, raw_d)] = L

    if not ap:
        return [
            "khong tim thay `layer = \"landing-zone/...\"` o dau ca. Day KHONG "
            "phai 'moi layer deu duoc phu' - la CHUA DOC DUOC."
        ], os.path.basename(nguon), None

    ####################################
    # PHU THEO PIPELINE, KHONG THEO TAP TIEN TO CHUNG
    #
    # Truoc day phep kiem gop moi tien to cua moi pipeline lai roi hoi
    # "co tien to nao cham vao layer L khong". Cau do tra loi sai khi
    # layer LONG NHAU:
    #
    #   landing-zone/network/       trong ban do cua vending
    #   landing-zone/network/ops/   layer RIENG, pipeline rieng
    #
    # "landing-zone/network/ops/" bat dau bang "landing-zone/network/",
    # nen network/ops trong nhu da duoc phu - trong khi pipeline phu no
    # (vending) KHONG apply layer do. Mot duong tinh gia theo chieu nguy
    # hiem: no che di dung cai cho trong ma phep kiem nay sinh ra de tim.
    #
    # Cau dung la: layer L duoc phu khi co MOT pipeline vua APPLY L vua
    # co mot tien to cham vao L.
    ####################################
    def phu(L):
        for ten, layers in ap.items():
            if L in layers and any((L + "/").startswith(p) for p in ban_do.get(ten, []) if p):
                return True
        return False

    sot = sorted(
        L
        for layers in ap.values()
        for L in layers
        if L not in thu_cong and not phu(L)
    )

    loi = []

    ####################################
    # 15. KHAI THU CONG MA THUC RA DA CO DUONG - HAI CAU TRAI NGUOC
    #
    # layer_thu_cong noi "layer nay duoc pipeline apply nhung CO Y khong co
    # duong kich hoat tu dong". phu(L) noi nguoc lai: co mot pipeline vua
    # APPLY L vua co tien to cham vao L. Ca hai dung ve cung mot layer la
    # mot cau tu mau thuan.
    #
    # De sot KHONG lam gi hong: pipeline van chay binh thuong. Dau hieu duy
    # nhat la output cua trigger-filter in layer do duoi muc "LAYER KHONG
    # CO DUONG TU DONG" - mot cau SAI trong dung cai bao cao ma nguoi ta
    # doc de biet thu gi dang duoc tu dong hoa.
    #
    # Da gan xay ra khi mo "ops-network": huong dan cu la "khi mo thi xoa
    # landing-zone/network/ops khoi layer_thu_cong" - mot buoc phai NHO, o
    # hai file khac nhau.
    #
    # ------------------------------------------------------------------
    # DUNG LAI phu() CHU KHONG TU SO KHOP - va day la ly do
    #
    # Ban dau phep kiem nay giao thang hai danh sach: tien to nao trong
    # ban_do cung nam trong layer_thu_cong thi bao. No keu NGAY, va keu
    # SAI: sau khi ban_do cua ops-network noi rong thanh
    # "landing-zone/network/", tien to do phu ca layer CHA - ma pipeline
    # ops-network KHONG apply layer cha, no apply network/ops.
    #
    # ban_do noi ve KICH HOAT, layer_thu_cong noi ve APPLY. Hai truc khac
    # nhau, va chi mau thuan khi CUNG MOT pipeline lam ca hai - dung dieu
    # phu() da kiem. Khoi chu thich ngay tren phu() mo ta chinh cai bay do,
    # va no duoc viet ra truoc phep kiem nay.
    ####################################
    mau_thuan = sorted(L for L in thu_cong if phu(L))
    if mau_thuan:
        loi.append(
            "trigger-filter: " + ", ".join(mau_thuan) + " khai o layer_thu_cong "
            "(\"co y khong co duong tu dong\") nhung CO mot pipeline vua apply "
            "layer do vua co tien to trong ban_do cham vao no. Hai cau trai "
            "nguoc nhau - xoa khoi layer_thu_cong."
        )

    if sot:
        loi.append(
            f"Layer duoc pipeline APPLY nhung khong duong dan nao trong ban_do "
            f"cham toi, va cung khong khai o layer_thu_cong: {sot}. "
            f"(doc tu {os.path.basename(nguon)}) "
            "Thay doi cua chung vao main roi nam do - khong gi chay, khong gi bao."
        )

    # Chieu nguoc: khai thu cong mot layer ma KHONG pipeline nao apply.
    # Vo hai luc chay, nhung no la mot ngoai le da het han - no noi rang
    # co mot cho trong o dau do, trong khi cho do khong con.
    moi_layer = set().union(*ap.values())
    thua = sorted(thu_cong - moi_layer)
    if thua:
        loi.append(
            f"layer_thu_cong khai layer khong pipeline nao apply: {thua}. "
            "Ngoai le da het han - xoa di, neu khong no se che mat mot cho "
            "trong that su xuat hien sau nay o cung duong dan."
        )

    return loi, os.path.basename(nguon), ap


####################################
# TIEN TO TRONG ban_do MA KHONG PHAI LAYER - DANH SACH DUY NHAT
#
# Mot tien to hop le khi mot pipeline APPLY layer nam duoi no. Ngoai le
# duy nhat: code duoc buildspec doc tu SOURCE luc build, chu khong phai
# tu state.
#
#   buildspec-terraform.yml:268
#     GATE="${CODEBUILD_SRC_DIR}/landing-zone/ops-gate/gate.py"
#
# gate.py doc tu thu muc lam viec cua CodeBuild, nen sua no la lan chay
# sau da dung luat moi - khong can apply gi. Do la ly do ops-gate/ co
# trong ban do cua bon pipeline, va la ly do danh sach nay ton tai thay
# vi mot dong "cho phep tat ca".
####################################
TIEN_TO_KHONG_PHAI_LAYER = {
    "landing-zone/ops-gate/": "buildspec doc gate.py tu CODEBUILD_SRC_DIR luc build",
}


def kiem_tien_to_co_ich(ap):
    """11. Tien to nao trong ban_do ma chay pipeline KHONG the ap dung.

    =====================================================================
    CHIEU NGUOC CUA PHEP KIEM 10

    Phep 10 hoi: layer nao duoc apply ma khong tien to nao cham toi.
    Phep nay hoi: tien to nao co do ma khong pipeline nao apply duoc.

    Hai chieu hong khac nhau han. Phep 10 bat mot layer BI BO ROI - im
    lang. Phep nay bat mot tien to SINH RA TIN HIEU SAI - on ao, va on ao
    theo huong te hon: pipeline chay, xanh, va nguoi doc ket luan thay
    doi da co hieu luc.

    =====================================================================
    VI DU THAT, VA NO SUYT DUOC LAM

    "modules/tf-pipeline/" trong nhu mot cho bo sot: module dung chung
    cho ca nam pipeline, sua no xong thi khong pipeline nao chay lai.
    Them tien to do vao ban_do nghe rat hop ly.

    Nhung no SAI, vi:

      modules/tf-pipeline/codebuild.tf:143
        buildspec = file("${path.module}/templates/buildspec-terraform.yml")

    buildspec duoc NHUNG vao cau hinh CodeBuild luc `terraform apply`,
    khong doc tu source luc build. Va pipeline thi apply layer NGHIEP VU
    cua no (organization, permission-sets, ...), khong bao gio apply dinh
    nghia cua chinh no.

    Nen chay pipeline sau khi sua module = chay mot thu KHONG THE ap dung
    thay doi do. Muon co hieu luc thi phai apply tay nam layer caller.

    Cung ly do do voi landing-zone/ops-pipeline*/,
    landing-zone/vending-pipeline/ va landing-zone/trigger-filter/: tat
    ca deu la code dinh nghia duong ong, apply bang tay.

    =====================================================================
    CHO HO THAT THI NAM O CHO KHAC

    Khong ai `plan` nam layer caller ca - khong pipeline nao, va project
    drift cung khong (no chi plan cac layer trong local.stage_keys). Nen
    mot thay doi module nam do khong duoc ap dung, voi dung zero tin
    hieu. Phep kiem nay KHONG chua duoc cho do; no chi chan cach chua
    sai. Cho do can mot buoc apply tay co nguoi lam.
    """
    that = os.path.join(TF, "terraform.tfvars")
    mau = os.path.join(TF, "terraform.tfvars.example")
    nguon = that if os.path.exists(that) else mau
    if not os.path.exists(nguon):
        return [
            "trigger-filter: khong co terraform.tfvars lan .example, nen phep kiem "
            "tien to co ich KHONG chay. Day KHONG phai 'khong co gi sai'."
        ]

    ban_do = ban_do_theo_pipeline(boc(open(nguon).read()))
    if not ban_do:
        return [
            f"khong doc duoc tien to nao tu ban_do ({os.path.basename(nguon)}). "
            "Day KHONG phai 'moi tien to deu co ich' - la CHUA DOC DUOC."
        ]

    loi = []
    for ten, tien_to in sorted(ban_do.items()):
        for p in tien_to:
            if not p or p in TIEN_TO_KHONG_PHAI_LAYER:
                continue
            if any((L + "/").startswith(p) for L in ap.get(ten, set())):
                continue
            loi.append(
                f"ban_do['{ten}'] co tien to '{p}' ma pipeline do KHONG apply "
                f"layer nao duoi no (no apply: {sorted(ap.get(ten, set())) or 'khong gi'}). "
                "Sua code duoi duong dan do se lam pipeline chay MA KHONG ap dung "
                "duoc thay doi - mot lan xanh vo nghia, va nguoi doc se tuong la da "
                "co hieu luc. Neu day la code buildspec doc tu source luc build thi "
                "them vao TIEN_TO_KHONG_PHAI_LAYER kem ly do; neu la code dinh nghia "
                "duong ong (modules/tf-pipeline, ops-pipeline*, vending-pipeline, "
                "trigger-filter) thi no phai apply BANG TAY, khong qua ban do."
            )
    return loi


def kiem_project_duoc_phep():
    """12. Moi CodeBuild project pipeline GOI phai co trong policy cua role.

    =====================================================================
    LOI NAY DA XAY RA, VOI MOT CANH BAO VIET SAN NGAY CANH CHO SUA

    iam.tf co mot khoi chu thich noi dung dieu se xay ra:

      "Thieu mot cai o day KHONG hong luc apply - no hong luc pipeline
       chay, va thong bao la AccessDenied tren StartBuild."

    Stage Verify duoc them, project thu ba duoc tao, va dong trong iam.tf
    thi khong. `terraform apply` xanh - 1 to add, 2 to change - roi lan
    chay dau do voi

      User: .../qh11-lz-ops-pipeline is not authorized to perform:
      codebuild:StartBuild on resource: .../qh11-lz-ops-verify

    Mot canh bao viet ra khong chay duoc. Phep kiem nay la ban CHAY DUOC
    cua no.

    =====================================================================
    NO DOI CHIEU GI

    pipeline.tf: moi `ProjectName = aws_codebuild_project.X[0].name`
    iam.tf:      moi `aws_codebuild_project.X[0].arn`

    Ten X phai co ca hai ben. Thieu ben iam.tf = AccessDenied luc chay.
    Thua ben iam.tf = cap quyen cho mot project khong stage nao goi.

    KHONG doi chieu project `drift`: no khong do pipeline khoi chay ma do
    EventBridge, va quyen cua no nam o role events (aws_iam_role.events),
    mot policy khac.
    """
    p_pipe = os.path.join(M, "pipeline.tf")
    p_iam = os.path.join(M, "iam.tf")
    for f in (p_pipe, p_iam):
        if not os.path.exists(f):
            return [f"khong co {f} - phep kiem project duoc phep KHONG chay."]

    goi = set(re.findall(
        r"ProjectName\s*=\s*aws_codebuild_project\.(\w+)\[0\]\.name",
        open(p_pipe).read()))
    cho = set(re.findall(
        r"aws_codebuild_project\.(\w+)\[0\]\.arn",
        boc(open(p_iam).read())))

    if not goi:
        return [
            "khong doc duoc ProjectName nao trong pipeline.tf. Day KHONG phai "
            "'moi project deu duoc phep' - la CHUA DOC DUOC."
        ]

    loi = []
    thieu = sorted(goi - cho)
    if thieu:
        loi.append(
            f"pipeline goi project {thieu} nhung iam.tf KHONG cap "
            "codebuild:StartBuild cho chung. terraform apply se XANH, va lan chay "
            "dau do voi AccessDenied tren StartBuild - mot thong bao doc nhu "
            "pipeline bi hong quyen chu khong nhu mot dong con thieu."
        )

    # Chieu nguoc: cap quyen cho mot project khong ai goi. Vo hai luc chay,
    # nhung no la quyen thua - va quyen thua thi khong ai di tim.
    thua = sorted(cho - goi - {"drift"})
    if thua:
        loi.append(
            f"iam.tf cap StartBuild cho project {thua} ma khong stage nao goi. "
            "Quyen thua khong gay loi nen khong ai di tim - xoa neu khong con "
            "dung, hoac them stage neu quen."
        )
    return loi


def kiem_thuoc_tinh_stage():
    """13. Moi `stage.value.X` trong pipeline.tf phai co trong kieu cua var.stages.

    =====================================================================
    LOI NAY DA XAY RA, VA NO IM HOAN TOAN

    ops-pipeline-network truyen `assume_role_arn` trong tung stage. Kieu
    cua var.stages khong khai thuoc tinh do, va Terraform AM THAM BO
    thuoc tinh thua khi ep object ve kieu da khai - khong loi, khong
    canh bao.

    Caller apply XANH voi 25 resource. Nhung ASSUME_ROLE_ARN den
    CodeBuild la chuoi rong, buildspec bo qua dong export, provider cua
    network/ops roi ve `profile`, va lan chay dau chet o

      Error: failed to get shared config profile, default

    mot thong bao ve ~/.aws/config, cach nguyen nhan that ba lop. Dau
    hieu duy nhat trong log la mot dong VANG MAT.

    `try(stage.value.assume_role_arn, "")` lam lop im lang thu hai: no
    bien "thuoc tinh khong ton tai" - mot loi to - thanh chuoi rong.

    =====================================================================
    NO DOI CHIEU GI

    pipeline.tf:   moi `stage.value.<ten>`
    variables.tf:  cac ten trong `variable "stages" { type = list(object({...}))}`

    Thieu ben variables.tf = gia tri bi bo trong im lang.
    """
    loi = []
    pl = os.path.join(M, "pipeline.tf")
    va = os.path.join(M, "variables.tf")
    if not os.path.exists(pl) or not os.path.exists(va):
        return ["khong doc duoc pipeline.tf hoac variables.tf cua module"]

    dung = set(re.findall(r"stage\.value\.([A-Za-z_][A-Za-z0-9_]*)", open(pl).read()))

    tv = open(va).read()
    m = re.search(r'variable\s+"stages"\s*\{.*?type\s*=\s*list\(object\(\{(.*?)\}\)\)',
                  tv, re.S)
    if not m:
        return ["khong tim thay kieu list(object({...})) cua variable \"stages\""]

    khai = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", m.group(1), re.M))

    # ------------------------------------------------------------------
    # MODULE TU THEM VAI THUOC TINH - CHUNG KHONG DEN TU CALLER
    #
    # main.tf co `stages = [for ... : merge(s, { thu_tu = ..., co_duyet =
    # ..., ... })]`, va pipeline.tf lap tren local do chu khong tren
    # var.stages. Nen stage.value.co_duyet la HOP LE du kieu cua
    # var.stages khong khai no.
    #
    # Ban dau phep kiem nay khong tru chung ra va keu ngay ba cai
    # (co_duyet, ro_apply, ro_duyet) - ca ba deu sai. Mot phep kiem keu
    # sai con te hon khong co, vi no day nguoi ta toi cho sua mot thu
    # dang dung.
    #
    # DOC tu main.tf chu khong viet cung: them mot thuoc tinh tinh o do
    # ma phai nho sua danh sach o day thi mot ngay nao do se khong ai nho.
    # ------------------------------------------------------------------
    mm = os.path.join(M, "main.tf")
    tu_them = set()
    if os.path.exists(mm):
        m2 = re.search(r"stages\s*=\s*\[\s*\n\s*for .*?merge\(s,\s*\{(.*?)\}\)",
                       open(mm).read(), re.S)
        if m2:
            tu_them = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=",
                                     m2.group(1), re.M))

    thieu = sorted(dung - khai - tu_them)
    if thieu:
        loi.append(
            "pipeline.tf doc stage.value." + ", stage.value.".join(thieu)
            + " nhung kieu cua var.stages khong khai chung. Terraform BO"
            " thuoc tinh thua trong im lang, nen gia tri caller truyen se"
            " mat ma khong co loi nao. Them `" + thieu[0]
            + " = optional(...)` vao kieu do."
        )
    return loi


def kiem_quyen_doc_log():
    """14. Caller co `verify` phai cap bon action ma kiem-log.sh can.

    =====================================================================
    LOI NAY DA XAY RA, VA NO DO SAU MOT BAO CAO XANH

    buildspec-verify.yml goi ops-gate/kiem-log.sh LUON sau lenh verify cua
    tung pipeline. Script do doc log cua chinh lan chay, nen no can bon
    action chi-doc. Thieu chung thi phan layer chay xong, in ra mot bao
    cao hoan toan xanh, roi stage do o

      AccessDeniedException ... codepipeline:ListPipelineExecutions

    Da xay ra o ops-pipeline-network: ba caller kia co khoi quyen do tu
    khi stage Verify duoc them, cai nay duoc noi verify sau va phan IAM
    khong di theo.

    =====================================================================
    DOI CHIEU THEO ACTION, KHONG THEO TEN Sid

    ops-pipeline cap dung bon action nay duoi Sid "DocChoVerify" (gop voi
    quyen doc tag policy), con ba caller kia dung "DocLogChoVerify". Ca
    hai deu hop le. Kiem theo ten Sid se bao hong mot thu dang chay -
    dung loai canh bao sai ma repo nay coi la te hon khong co canh bao.
    """
    CAN = [
        "codepipeline:ListPipelineExecutions",
        "codepipeline:ListActionExecutions",
        "logs:GetLogEvents",
        "logs:DescribeLogStreams",
    ]
    loi = []
    for d in sorted(glob.glob(os.path.join(GOC, "landing-zone/ops-pipeline*"))):
        f = os.path.join(d, "main.tf")
        if not os.path.isfile(f):
            continue
        # BO DONG CHU THICH TRUOC KHI TIM
        #
        # Kiem dot bien dau tien KHONG keu, va ly do la chinh khoi chu
        # thich moi them vao ops-pipeline-network: no co dong
        #
        #   #   AccessDeniedException ... codepipeline:ListPipelineExecutions
        #
        # nen chuoi van "tim thay" du dong CAP QUYEN da bi xoa. Van ban MO
        # TA mot quyen bi doc thanh quyen do - cung lop loi voi kiem-log.sh
        # bat `echo "CANH BAO..."` va bat van ban trong output cua Terraform.
        #
        # Mot phep kiem doc ca chu thich la mot phep kiem co the duoc lam
        # cho im bang cach viet them mot dong van xuoi.
        noi_dung = "\n".join(
            d for d in open(f).read().splitlines() if not d.lstrip().startswith("#")
        )
        if not re.search(r"(?<![\w])verify\s*=", noi_dung):
            continue
        thieu = [a for a in CAN if a not in noi_dung]
        if thieu:
            loi.append(
                os.path.basename(d) + " khai `verify` nhung quyen_dich_vu thieu "
                + ", ".join(thieu)
                + ". kiem-log.sh se do voi AccessDenied SAU khi phan layer da in"
                " mot bao cao xanh."
            )
    return loi


def kiem_loosen_co_stage():
    """16. Layer co tu HAI stage thi moi muc loosen phai co truong `stage`.

    =====================================================================
    LOI NAY DA XAY RA, VA NO GIET MOT STAGE CO BAN PLAN SACH

    ops-loosen.yaml la MOT file cho ca layer, nhung gate.py chay theo TUNG
    STAGE voi mot ban plan da -target. Nen mot khai bao cho stage A la
    "khong dung toi" duoi mat stage B, va --strict bien canh bao do thanh
    mot lan do.

    O ops-network: khai bao ingress rule cua cloudops-firewall lam stage
    cloudops-network CHET, du plan cua no bao "0 loi". Thong bao noi ve mot
    khai bao thua, khong noi gi ve viec no thuoc stage khac.

    landing-zone/organization co BA stage dung chung mot file - cung bay.

    =====================================================================
    NO DOI CHIEU GI

    caller main.tf:  cac cap (key, layer) trong local.stages
    <layer>/ops-loosen.yaml: moi muc phai co `stage`, va gia tri do phai la
                             mot key that cua layer do

    Chi bat buoc khi layer co >= 2 stage: mot stage thi khong the nham.
    """
    loi = []
    for d in sorted(glob.glob(os.path.join(GOC, "landing-zone/ops-pipeline*"))):
        f = os.path.join(d, "main.tf")
        if not os.path.isfile(f):
            continue
        noi_dung = "\n".join(
            x for x in open(f).read().splitlines() if not x.lstrip().startswith("#")
        )
        cap = re.findall(
            r'key\s*=\s*"([^"]+)"[\s\S]{0,400}?layer\s*=\s*"([^"]+)"', noi_dung
        )
        theo_layer = {}
        for k, L in cap:
            theo_layer.setdefault(L, []).append(k)

        for L, keys in theo_layer.items():
            fl = os.path.join(GOC, L, "ops-loosen.yaml")
            if len(keys) < 2 or not os.path.isfile(fl):
                continue
            try:
                import yaml
                doc = yaml.safe_load(open(fl)) or {}
            except Exception as e:
                loi.append(f"{L}/ops-loosen.yaml khong doc duoc: {e}")
                continue
            for m in doc.get("loosen") or []:
                dc = m.get("address", "(khong co address)")
                if not m.get("stage"):
                    loi.append(
                        f"{L}/ops-loosen.yaml: muc {dc} THIEU truong `stage`, "
                        f"ma layer nay co {len(keys)} stage ({', '.join(keys)}). "
                        "gate.py se xet khai bao o CA cac stage, va stage nao "
                        "khong noi long se bao 'khai bao KHONG dung toi' roi do "
                        "duoi --strict - du ban plan cua no sach."
                    )
                elif m["stage"] not in keys:
                    loi.append(
                        f"{L}/ops-loosen.yaml: muc {dc} khai stage "
                        f"{m['stage']!r} khong co trong layer nay. Stage that: "
                        f"{', '.join(keys)}. Khai sai ten thi gate.py bo qua "
                        "khai bao, va NOI se bi chan nhu chua khai gi."
                    )
    return loi


def kiem_push_tfvars(ap):
    """11. push-tfvars.sh phai phu het layer ma cac pipeline apply.

    =====================================================================
    VI SAO

    Buildspec keo terraform.tfvars cua layer tu S3. Thieu file do la LOI
    CUNG trong buildspec (loi 97), nhung danh sach layer duoc day len lai
    nam trong mot mang bash VIET TAY o push-tfvars.sh.

    Hai danh sach phai dong y voi nhau, va khi lech thi:
      - luc day file:      khong co loi, script bao xong
      - luc pipeline chay: loi noi ve S3, khong noi ve script nao

    Chinh script do da ghi canh bao nay trong chu thich cua no. Mot canh
    bao trong chu thich khong chay duoc; phep kiem nay chay duoc.
    """
    p = os.path.join(GOC, "landing-zone/vending-pipeline/push-tfvars.sh")
    if not os.path.exists(p):
        return ["khong tim thay push-tfvars.sh. KHONG phai 'khong co gi sai' - la CHUA DOC DUOC."]

    raw = open(p).read()
    m = re.search(r"^LAYERS=\((.*?)^\)", raw, re.S | re.M)
    if not m:
        return ["push-tfvars.sh: khong tim thay mang LAYERS=( ... )."]

    # Bo dong bi comment: mot muc bi comment la mot muc KHONG duoc day.
    than = re.sub(r"#[^\n]*", "", m.group(1))
    day = set(re.findall(r'"([^"]+)"', than))
    if not day:
        return ["push-tfvars.sh: mang LAYERS RONG. KHONG phai 'khong co gi de day'."]

    can = set().union(*ap.values())
    thieu = sorted(can - day)
    loi = []
    if thieu:
        loi.append(
            f"push-tfvars.sh thieu layer ma pipeline se apply: {thieu}. "
            "Thieu o day khong gay loi luc day file - no gay loi luc pipeline "
            "chay, va thong bao noi ve S3 chu khong noi ve script nao."
        )

    # Chieu nguoc chi la CANH BAO, khong phai loi: layer chua co pipeline
    # van can tfvars tren S3 neu mot ngay nao do no duoc them vao mot
    # stage. Nen o day khong kiem `day - can`.
    return loi


def main():
    callers = sys.argv[1:] or tim_caller()

    mt_raw = doc(M)
    if not mt_raw.strip():
        print(f"  LOI  khong doc duoc file .tf nao o module: {M}")
        print("       Day KHONG phai 'khong co gi sai' - la CHUA DOC DUOC.")
        return 1

    # CHOT CHAN: 0 caller khong phai "moi caller deu khop".
    if not callers:
        print("  LOI  khong tim thay caller nao cua modules/tf-pipeline.")
        print("       Day KHONG phai 'khong co gi sai' - la CHUA TIM DUOC.")
        return 1

    mt = boc(mt_raw)
    loi = kiem_module(mt_raw, mt)
    print(f"module: {len(khai(mt_raw))} bien, {len(outs(mt_raw))} output, {len(locals_khai(mt_raw))} local")

    for C in callers:
        ten = os.path.basename(C.rstrip("/"))
        l = kiem_caller(C, mt_raw, ten)
        print(f"  {'x' if l else 'v'} {ten}")
        loi += l

    # Chi quet layer don khi TU TIM caller. Neu nguoi ta neu ro thu muc
    # tren dong lenh thi ho dang hoi ve nhung thu muc do, khong phai ve
    # ca cay.
    don = [] if sys.argv[1:] else tim_layer_don(callers)
    if don:
        print(f"layer khong dung module: {len(don)}")
        for d in don:
            ten = os.path.basename(d.rstrip("/"))
            l = kiem_layer_don(d, ten)
            print(f"  {'x' if l else 'v'} {ten}")
            loi += l

    # Chi khi TU TIM: phep kiem nay hoi ve ca cay, khong ve mot thu muc.
    phu_nguon = None
    if not sys.argv[1:]:
        l, phu_nguon, ap = kiem_phu_layer()
        if phu_nguon:
            print(f"  {'x' if l else 'v'} do phu layer (doc {phu_nguon})")
        loi += l

        l2 = kiem_push_tfvars(ap) if ap else []
        if ap:
            print(f"  {'x' if l2 else 'v'} push-tfvars phu het layer")
        loi += l2

        l3 = kiem_tien_to_co_ich(ap) if ap else []
        if ap:
            print(f"  {'x' if l3 else 'v'} moi tien to trong ban_do co ich")
        loi += l3

        l4 = kiem_project_duoc_phep()
        print(f"  {'x' if l4 else 'v'} moi project pipeline goi deu duoc cap StartBuild")
        loi += l4

        l5 = kiem_thuoc_tinh_stage()
        print(f"  {'x' if l5 else 'v'} moi stage.value.X co trong kieu cua var.stages")
        loi += l5

        l6 = kiem_quyen_doc_log()
        print(f"  {'x' if l6 else 'v'} caller co verify deu cap quyen doc log")
        loi += l6

        l7 = kiem_loosen_co_stage()
        print(f"  {'x' if l7 else 'v'} loosen cua layer nhieu stage deu co `stage`")
        loi += l7

    print()
    if loi:
        print("\n".join("  LOI  " + x for x in loi))
        return 1
    print(f"  Khop het: module + {len(callers)} caller + {len(don)} layer don.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
