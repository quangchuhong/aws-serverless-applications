"""Loc su kien commit: chi khoi dong pipeline co duong dan bi dong toi.

=========================================================================
VI SAO PHAI CO MOT HAM O GIUA

Su kien "CodeCommit Repository State Change" KHONG chua danh sach file da
doi. No chi co repositoryName, commitId, oldCommitId, referenceName. Nen
thong tin de loc khong ton tai o tang luat EventBridge - khong phai la
chua ai viet luat do, ma la khong the viet.

(CodePipeline V2 loc duoc theo duong dan, nhung chi voi nguon kieu
connection - GitHub, GitLab, Bitbucket. Voi CodeCommit thi khong.)

Thu CO trong su kien la hai commit id. Ham nay goi GetDifferences giua
chung roi doi chieu voi ban do duong dan.

=========================================================================
HONG THI CHAY, KHONG PHAI HONG THI THOI

Day la quyet dinh quan trong nhat trong ca file.

Khi khong doc duoc diff - API loi, het gio, thieu quyen, commit bi ep
day - ham nay khoi dong MOI pipeline trong ban do.

Vi sao khong lam nguoc lai: mot lan chay thua la vai phut CodeBuild va
mot dong log. Mot lan KHONG chay la mot thay doi da merge vao main ma
khong bao gio den AWS - va khong co gi bao, vi pipeline "khong chay"
trong giong het "khong co gi de chay".

Do dung la khuyet diem da lap muoi lan trong du an nay: mot phep doc hong
tra ve rong, va rong bi doc thanh mot cau tra loi. O day rong se co nghia
la "khong file nao lien quan" - mot cau tra loi rat de tin va rat sai.

=========================================================================
NAM CACH BAN DO CO THE SAI, VA CA NAM DEU IM LANG

Bo loc nay dung GIUA su kien va pipeline. Khi no sai, khong co gi do -
pipeline khong chay trong giong het khong co gi de chay. Nen nam phep kiem
duoi day chay MOI LAN goi, va deu la loi CUNG:

  1. BAN_DO rong          -> chan sach moi thay doi, bao thanh cong
  2. mot pipeline co danh sach tien to RONG
                          -> str.startswith(()) luon False, nen pipeline
                             do khong bao gio chay. Mot dong `[]` trong
                             tfvars doc giong "chua dien" va chay giong
                             "da tat".
  3. BAN_DO goi ten mot pipeline KHONG CO that (go sai)
                          -> StartPipelineExecution nem loi
  4. TRU goi ten pipeline khong co trong BAN_DO
                          -> mot ngoai le da het han
  5. TRU chan sach mot tien to trong BAN_DO
                          -> cung dang voi (2) nhung kho thay hon: hai
                             dong deu co noi dung, phai doc CA HAI moi
                             biet cai sau vo hieu hoa cai truoc

Va mot chieu nua, chieu NGUY HIEM hon ca nam: mot pipeline CO that, da tat
rule rieng cua no, nhung KHONG CO trong BAN_DO. Luc do khong con duong
nao kich hoat no. TIEN_TO_PHU bat chieu do - xem kiem_ban_do().
"""

import json
import os

import boto3

cc = boto3.client("codecommit")
cp = boto3.client("codepipeline")


def ten_pipeline_o_aws():
    """Ten moi pipeline trong account/region nay."""
    ra = set()
    for p in cp.get_paginator("list_pipelines").paginate():
        for x in p.get("pipelines", []):
            ra.add(x["name"])
    return ra


def khop(duong_dan, gom, tru):
    """Duong dan khop `gom` va KHONG khop `tru`.

    =====================================================================
    VI SAO CAN `tru`

    Layer co the LONG NHAU trong cay thu muc:

      landing-zone/network/       <- pipeline vending apply (stage B, D)
      landing-zone/network/ops/   <- layer RIENG, pipeline rieng, state rieng

    So khop la so khop CHUOI, nen tien to "landing-zone/network/" bat ca
    moi file trong "network/ops/". Khong co cach nao viet mot tien to
    nghia la "network/ nhung khong network/ops/".

    Hau qua neu bo qua: sua lop van hanh mang - thu doi HANG NGAY - keo
    vending chay vo ich, kem mot cong duyet treo mang nhan "tao account".
    """
    return sorted(
        d for d in duong_dan
        if d.startswith(tuple(gom)) and not (tru and d.startswith(tuple(tru)))
    )


def kiem_ban_do(ban_do, tru, tien_to_phu):
    """Nam phep kiem cau truc + mot phep kiem do phu. Loi CUNG.

    Tra ve (loi, kiem) - `kiem` noi hai phep kiem can AWS co CHAY hay
    khong. Xem chu thich trong than ham: "dat" va "khong chay" phai
    trong khac nhau tu ben ngoai.
    """
    loi = []

    # 1. BAN_DO rong khong phai "khong co gi de chay".
    if not ban_do:
        loi.append(
            "BAN_DO rong: khong pipeline nao duoc khai. Day KHONG phai "
            "'khong co gi de chay' - la mot bo loc chan sach moi thay doi."
        )

    # 2. Danh sach tien to rong = pipeline khong bao gio chay.
    for ten, tien_to in sorted(ban_do.items()):
        if not tien_to:
            loi.append(
                f"{ten}: danh sach tien to RONG. startswith(()) luon False, "
                "nen pipeline nay khong bao gio duoc khoi dong. Muon no chay "
                'voi moi commit thi khai [""], khong phai [].'
            )

    # 4. TRU goi ten pipeline khong co trong BAN_DO.
    #
    # Vo hai luc chay - vong lap duyet BAN_DO nen muc do khong ai doc.
    # Nhung no la mot phan TRU da het han: no noi rang co mot ngoai le
    # dang co hieu luc, trong khi khong.
    if set(tru) - set(ban_do):
        loi.append(
            f"TRU goi ten pipeline khong co trong BAN_DO: "
            f"{sorted(set(tru) - set(ban_do))}. Muc tru do khong co hieu luc."
        )

    # 5. TRU CHAN SACH MOT TIEN TO GOM.
    #
    # Cung dang voi danh sach tien to rong, nhung kho thay hon nhieu: hai
    # dong deu co noi dung, va phai doc CA HAI moi biet cai thu hai vo
    # hieu hoa cai thu nhat.
    #
    #   gom = ["landing-zone/network/"]
    #   tru = ["landing-zone/"]          <- gom khong bao gio khop nua
    for ten, gom in sorted(ban_do.items()):
        for p in gom:
            chan = [e for e in tru.get(ten, []) if e and p.startswith(e)]
            if chan:
                loi.append(
                    f"{ten}: tien to gom \"{p}\" bi TRU chan sach boi {chan}. "
                    "No khong bao gio khop duoc, nen pipeline nay coi nhu khong "
                    "co tien to do."
                )

    # 3 va phep do phu can biet AWS co gi. Doc hong thi NOI RA chu khong bo qua -
    #    bo qua o day nghia la hai phep kiem duoi im lang bien mat.
    #
    # ---------------------------------------------------------------
    # "DAT" VA "KHONG CHAY" PHAI TRONG KHAC NHAU
    #
    # Truoc day ca hai deu tra ve `loi` rong, va thu duy nhat phan biet
    # chung la mot dong CANH BAO trong log. Mot lan chay that da cho thay
    # van de: ket qua ra {"loc": true, ...} va khong co cach nao biet
    # `kiem_do_phu` da chay hay da im lang bien mat - phai mo log ra doc,
    # va phai biet TRUOC la can tim dong nao.
    #
    # Do dung la khuyet diem ca file nay duoc viet de chong. Nen trang
    # thai di theo gia tri TRA VE, khong chi nam trong log.
    try:
        co_that = ten_pipeline_o_aws()
    except Exception as e:
        print(f"CANH BAO: khong liet ke duoc pipeline ({type(e).__name__}: {e}).")
        print("  -> hai phep kiem 'ten co that' va 'do phu' KHONG chay lan nay.")
        return loi, f"THIEU: khong liet ke duoc pipeline ({type(e).__name__})"

    # 3. Ten go sai. Khong sua duoc bang cach thu lai, nhung van phai on ao.
    thua = sorted(set(ban_do) - co_that)
    if thua:
        loi.append(
            f"BAN_DO goi ten pipeline khong co that: {thua}. "
            f"Pipeline dang co: {sorted(co_that)}"
        )

    # DO PHU - CHIEU NGUY HIEM: pipeline co that ma khong ai kich hoat.
    #
    # Sau khi tat rule EventBridge rieng cua tung pipeline, BAN_DO la
    # duong DUY NHAT den chung. Mot pipeline bi quen o day van "ton tai",
    # van xanh trong console, va khong bao gio chay nua.
    #
    # ---------------------------------------------------------------
    # PHEP KIEM NAY BAO DAM DUNG MOT DIEU, KHONG HON
    #
    #   "moi pipeline TEN BAT DAU BANG tien_to_phu deu co trong BAN_DO"
    #
    # KHONG phai "moi pipeline cua landing zone deu co trong BAN_DO".
    # Hai cau do trung nhau CHI VI ten pipeline do Terraform ghep:
    # modules/tf-pipeline va vending-pipeline deu dat
    # local.name = "${var.project}-${var.ten}". Con pipeline dat ten tay
    # thi no khong thay.
    #
    # Da do that, hai lan cach nhau vai ngay:
    #
    #   lan dau  5 pipeline, 3 mang tien to "qh11-lz-"
    #   sau do   7 pipeline, 5 mang tien to "qh11-lz-"
    #
    # Hai con so deu tang khi bat them pipeline van hanh, va chung se con
    # doi nua - dung dung con so o day de ket luan bat cu dieu gi ve hien
    # tai, doc dong "Ban do da doi chieu voi AWS" trong log.
    #
    # Nhung cai KHONG mang tien to (MyImagePipeline1,
    # shopping-cart-pipeline) khong thuoc landing zone nen khong sao -
    # va do la mot ket luan rut ra tu viec NHIN danh sach, khong phai tu
    # viec phep kiem im lang.
    if tien_to_phu:
        sot = sorted(
            t for t in co_that
            if t.startswith(tien_to_phu) and t not in ban_do
        )
        if sot:
            loi.append(
                f"Pipeline co tien to '{tien_to_phu}' nhung KHONG co trong "
                f"BAN_DO: {sot}. Neu rule EventBridge rieng cua chung da tat "
                "thi khong con duong nao kich hoat chung - chung se im lang "
                "khong chay nua."
            )

    # Dong nay la mot khang dinh CO NOI DUNG, khong phai su vang mat cua
    # mot canh bao: no noi da doi chieu voi bao nhieu pipeline that.
    phu = f"{len(ban_do)}/{len(co_that)} pipeline"
    if tien_to_phu:
        mang_tien_to = [t for t in co_that if t.startswith(tien_to_phu)]
        phu = f"{len(ban_do)} trong ban do, {len(mang_tien_to)} mang tien to '{tien_to_phu}', {len(co_that)} tong"
    print(f"Ban do da doi chieu voi AWS: {phu}")

    return loi, f"DAY DU: {phu}"


def duong_dan_da_doi(repo, truoc, sau):
    """Moi duong dan bi cham giua hai commit. Co phan trang."""
    ra = set()
    trang = cc.get_paginator("get_differences")
    for p in trang.paginate(
        repositoryName=repo,
        beforeCommitSpecifier=truoc,
        afterCommitSpecifier=sau,
    ):
        for d in p.get("differences", []):
            # Doi ten mot file cham CA HAI duong dan, nen lay ca hai.
            for phia in ("afterBlob", "beforeBlob"):
                if d.get(phia, {}).get("path"):
                    ra.add(d[phia]["path"])
    return ra


def khoi_dong(ten, vi_sao, hong):
    """Khoi dong mot pipeline. Loi duoc GHI LAI chu khong nem ngay.

    Nem ngay se lam mot ten go sai chan het nhung pipeline dung dang xep
    sau no trong vong lap - tuc mot loi go phim thanh mot lan bo sot.
    """
    try:
        cp.start_pipeline_execution(name=ten)
        print(f"KHOI DONG  {ten}  ({vi_sao})")
        return True
    except Exception as e:
        print(f"HONG       {ten}  ({type(e).__name__}: {e})")
        hong.append(f"{ten}: {type(e).__name__}: {e}")
        return False


def chay_het(ban_do, vi_sao, hong):
    """Duong FAIL OPEN. Xem docstring dau file."""
    print(f"KHONG LOC DUOC: {vi_sao}")
    print("  -> khoi dong MOI pipeline. Mot lan chay thua re hon mot lan bo sot.")
    da_chay = [t for t in sorted(ban_do) if khoi_dong(t, "fail-open", hong)]
    return {"loc": False, "ly_do": vi_sao, "da_khoi_dong": da_chay}


def handler(event, context):
    ban_do = json.loads(os.environ["BAN_DO"])
    tru = json.loads(os.environ.get("TRU", "{}"))
    tien_to_phu = os.environ.get("TIEN_TO_PHU", "")

    loi, kiem = kiem_ban_do(ban_do, tru, tien_to_phu)
    if loi:
        # Nem TRUOC khi cham vao pipeline nao: mot ban do sai thi khong
        # co ket qua nao cua no dang tin, ke ca phan "khop".
        raise RuntimeError("BAN_DO sai:\n  " + "\n  ".join(loi))

    detail = event.get("detail", {})
    repo = detail.get("repositoryName")
    sau = detail.get("commitId")
    truoc = detail.get("oldCommitId")

    print(f"repo={repo} truoc={truoc} sau={sau} nhanh={detail.get('referenceName')}")

    hong = []
    ket_qua = None

    if not repo or not sau:
        ket_qua = chay_het(ban_do, "su kien thieu repositoryName hoac commitId", hong)
    elif not truoc:
        # referenceCreated: nhanh vua duoc tao, khong co gi de so.
        ket_qua = chay_het(ban_do, "khong co oldCommitId (nhanh moi tao)", hong)
    else:
        try:
            duong_dan = duong_dan_da_doi(repo, truoc, sau)
        except Exception as e:  # FAIL OPEN - xem docstring dau file
            ket_qua = chay_het(
                ban_do, f"GetDifferences hong: {type(e).__name__}: {e}", hong
            )

    if ket_qua is None:
        ket_qua = doi_chieu(ban_do, tru, duong_dan, hong)

    # Di theo MOI duong tra ve, ke ca duong fail-open: cau hoi "hai phep
    # kiem can AWS co chay khong" khong phu thuoc vao viec doc duoc diff
    # hay khong, nen no khong duoc bien mat o nhanh nao.
    ket_qua["kiem_ban_do"] = kiem

    if hong:
        # Lambda phai BAO HONG o day. So Errors cua ham nay la cho duy
        # nhat viec "mot pipeline khong khoi dong duoc" lo ra - log thi
        # khong ai doc.
        #
        # EventBridge se goi lai (mac dinh 2 lan). Lan goi lai khoi dong
        # LAI nhung pipeline da chay - vo hai, CodePipeline thay the ban
        # chay dang cho bang ban moi. Doi lai la mot ten go sai se keu
        # ba lan thay vi mot.
        raise RuntimeError(
            "Khoi dong khong tron ven:\n  " + "\n  ".join(hong)
            + f"\n(da khoi dong duoc: {ket_qua.get('da_khoi_dong')})"
        )

    return ket_qua


def doi_chieu(ban_do, tru, duong_dan, hong):
    """Duong binh thuong: so duong dan da doi voi ban do."""
    if not duong_dan:
        # Diff rong that su xay ra: commit rong, hoac merge khong doi gi.
        # Khong co gi de chay, va do la ket luan DOC DUOC chu khong phai
        # mot phep doc hong - nen o day khong fail open.
        print("Diff rong: khong file nao doi. Khong khoi dong pipeline nao.")
        return {"loc": True, "duong_dan": [], "da_khoi_dong": []}

    print(f"{len(duong_dan)} duong dan doi:")
    for d in sorted(duong_dan):
        print(f"    {d}")

    da_chay, bo_qua = [], []
    for ten, gom in sorted(ban_do.items()):
        bo = tru.get(ten, [])
        kh = khop(duong_dan, gom, bo)
        if kh:
            if khoi_dong(ten, f"{len(kh)} duong dan khop, vi du {kh[0]}", hong):
                da_chay.append(ten)
        else:
            vi = f"khong duong dan nao khop {gom}"
            if bo:
                vi += f", tru {bo}"
            print(f"bo qua     {ten}  ({vi})")
            bo_qua.append(ten)

    return {"loc": True, "da_khoi_dong": da_chay, "bo_qua": bo_qua}
