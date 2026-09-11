#!/usr/bin/env python3
"""Cong chan SAU plan, TRUOC apply cho pipeline van hanh.

    python3 gate.py --plan tfplan.json --layer landing-zone/organization \
                    --stage sec-scp [--loosen ops-loosen.yaml] [--strict]

=========================================================================
VI SAO DOC BAN PLAN CHU KHONG DOC CATALOG

Cho SCP da co organization/lint.sh: no doc catalog/scp.yaml roi doi
chieu voi policy dang gan that o AWS. Lam duoc, va nhanh, va chay offline
cho nguoi mo PR.

Nhung chinh dau file lint.sh do tu thua nhan mot diem mu:

    co Condition <-> khong co Condition      (bat duoc)
    noi dung Condition A -> noi dung B       (KHONG bat duoc)
    ... la mot thay doi CODE trong scp-catalog.tf, di qua review code
    chu khong qua catalog.

Ban plan khong co diem mu do. No la thu SAP XAY RA, kem `before` va
`after` cua tung thuoc tinh - nen no thay ca thay doi sinh ra tu HCL,
khong chi thay doi trong YAML.

Doi lai: no can credential va mot lan plan, nen no KHONG thay duoc lint
offline. Hai thu bo nhau:

    lint.sh    truoc plan, khong can AWS, doc duoc Y NGHIA cua policy
    gate.py    sau plan, doc duoc MOI thay doi, khong doc y nghia

=========================================================================
BA NGUYEN HAM, VA MOT PHAM VI

    xoa_la_noi    resource la mot lop chan. Xoa no = mat lop chan do.
    tao_la_noi    resource la mot quyen. Tao no = cap them quyen.
    thuoc_tinh    don dieu: bool phai giu true, so khong duoc giam,
                  chuoi phai giu mot gia tri.
    pham_vi       stage nay duoc doi nhung type nao. Type khac = tu choi.

CHIEU KHONG GIONG NHAU GIUA CAC DICH VU, va day la cho de sai nhat:

    SCP              XOA mot Deny la noi
    permission-set   TAO mot assignment la noi - NGUOC HAN

Sao chep luat cua SCP sang permission-set se cho `+ AdministratorAccess`
chay tu do va chan viec thu hoi quyen. Nen bang luat duoi day ghi RO
chieu cho tung type, va moi dong co mot cau giai thich - neu khong doc
duoc vi sao, dong do khong nen o day.

=========================================================================
PHAM VI: CHOT CHAN CHO `TF_TARGETS` RONG

Pipeline gioi han tam voi -target. Neu TF_TARGETS rong hoac go sai ten
thi `terraform plan` KHONG bao loi - no chi plan CA layer. Voi layer
organization, ca layer nghia la cay OU va delegated administrator.

main.tf co mot check cho viec do, nhung no viet cung
`layer == "landing-zone/organization"`, nen permission-sets va org-trail
khong duoc bao ve.

pham_vi kiem o BAN PLAN chu khong o bien moi truong: no thay thu that su
sap doi, bat ke TF_TARGETS duoc dat dung hay khong.
"""

import argparse
import json
import os
import sys

R = "\033[31m"
Y = "\033[33m"
G = "\033[32m"
N = "\033[0m"

########################################
# BANG LUAT
#
# Moi muc: "vi sao" la bat buoc. Mot luat khong giai thich duoc la mot
# luat khong ai dam sua sau nay.
########################################

# fmt: off
LUAT = {
    ####################################
    # organization - SCP
    #
    # Noi dung policy (`content`) KHONG o day: do la viec cua
    # organization/lint.sh, no doc duoc Sid nao mat, action nao thu hep.
    # Lap lai o day se cho hai cau tra loi cho cung mot cau hoi, va khi
    # chung lech nhau se khong ai biet cai nao dung.
    ####################################
    "aws_organizations_policy_attachment": {
        "xoa_la_noi": "mot guardrail khong con gan vao dau - policy van ton tai nen no trong nhu khong co gi doi",
    },

    ####################################
    # organization - cay OU
    #
    # Xoa mot OU khong chi xoa mot cai hop: account trong do roi ve
    # root, va MOI SCP gan vao OU do het ap dung cho chung.
    ####################################
    "aws_organizations_organizational_unit": {
        "xoa_la_noi": "account trong OU roi ve root, va moi SCP gan vao OU do khong con ap dung cho chung",
        "thuoc_tinh": {
            "parent_id": ("bat_ky_doi", "chuyen ca nhanh OU sang cho khac - tap SCP ap dung doi hoan toan"),
        },
    },

    ####################################
    # permission-sets - CHIEU NGUOC VOI SCP
    #
    # O day TAO la noi. Moi resource duoi day, khi duoc tao, lam mot
    # nguoi co quyen ma truoc do khong co.
    ####################################
    "aws_ssoadmin_managed_policy_attachment": {
        "tao_la_noi": "gan them mot managed policy vao permission set - moi nguoi dang dung set do duoc them quyen ngay, khong can dang nhap lai",
    },
    "aws_ssoadmin_account_assignment": {
        "tao_la_noi": "gan mot permission set vao mot account cho mot group - ca group vao duoc account do",
    },
    "aws_identitystore_group_membership": {
        "tao_la_noi": "them mot nguoi vao group - nguoi do nhan toan bo assignment cua group",
    },
    "aws_ssoadmin_permission_set_inline_policy": {
        "thuoc_tinh": {
            "inline_policy": ("bat_ky_doi", "inline policy cua permission set doi - phai doc bang mat, cong nay khong hieu noi dung policy"),
        },
    },
    "aws_ssoadmin_permission_set": {
        "thuoc_tinh": {
            # ISO-8601 dang "PT8H". So sanh chuoi khong noi duoc cai nao
            # dai hon, nen chi bao "doi" va de nguoi doc.
            "session_duration": ("bat_ky_doi", "thoi gian phien doi - dai hon nghia la mot phien co quyen song lau hon"),
        },
    },

    ####################################
    # config-detective - Config  (chua vao pipeline - cho role lien account)
    #
    # Ten thuoc tinh o duoi day doc tu chinh code cua layer, khong phong
    # doan: aggregator-rules.tf:86 cho excluded_accounts,
    # guardduty.tf:225 / 412 / 431 va securityhub.tf:166 / 167 cho phan
    # con lai.
    ####################################
    "aws_config_config_rule": {
        "xoa_la_noi": "mot phep kiem bien mat - tai nguyen sai cau hinh se khong con bi danh dau",
    },
    "aws_config_organization_managed_rule": {
        "xoa_la_noi": "mot phep kiem toan to chuc bien mat",
        "thuoc_tinh": {
            # CHIEU NGUOC voi truc giac: tap nay LON LEN la noi long.
            # Moi account them vao day la mot account thoat khoi phep
            # kiem - va no thoat trong im lang, vi rule van "dang bat".
            "excluded_accounts": ("tap_khong_lon", "them account vao danh sach loai tru - account do thoat khoi phep kiem ma rule van trong nhu dang bat"),
        },
    },
    "aws_config_configuration_aggregator": {
        "xoa_la_noi": "mat cai nhin toan to chuc - tung account van ghi nhung khong con cho nao doc duoc ca to chuc",
    },
    "aws_config_configuration_recorder": {
        "xoa_la_noi": "ngung ghi lai cau hinh - moi phep kiem Config sau do khong co du lieu",
    },
    "aws_config_configuration_recorder_status": {
        "thuoc_tinh": {
            "is_enabled": ("bool_phai_true", "recorder bi tat - Config im lang chu khong bao loi"),
        },
    },
    # StackSet la thu day recorder xuong cac account thanh vien. Xoa no
    # khong xoa recorder ngay, nen no trong nhu vo hai - nhung account
    # TAO SAU do se khong co recorder nao, va khong co dong nao noi ra.
    "aws_cloudformation_stack_set": {
        "xoa_la_noi": "khong con day cau hinh xuong account thanh vien - account tao sau do se thieu no trong im lang",
    },
    "aws_cloudformation_stack_set_instance": {
        "xoa_la_noi": "go cau hinh khoi mot account/OU cu the",
    },

    ####################################
    # config-detective - Security Hub
    ####################################
    "aws_securityhub_account": {
        "xoa_la_noi": "tat Security Hub o mot account",
        "thuoc_tinh": {
            "auto_enable_controls": ("bool_phai_true", "control moi cua AWS se khong tu duoc bat - bo tieu chuan dung yen trong khi AWS them control"),
        },
    },
    "aws_securityhub_organization_configuration": {
        "thuoc_tinh": {
            "auto_enable":           ("bool_phai_true", "account TAO SAU khong tu duoc bat Security Hub - lo hong chi lo ra o account tiep theo, khong phai hom nay"),
            "auto_enable_standards": ("thu_tu:DEFAULT>NONE", "account moi khong duoc gan bo tieu chuan mac dinh"),
        },
    },
    "aws_securityhub_member": {
        "xoa_la_noi": "mot account khong con duoc Security Hub theo doi",
    },
    "aws_securityhub_standards_subscription": {
        "xoa_la_noi": "bo mot bo tieu chuan Security Hub - hang tram control tat cung mot luc",
    },
    "aws_securityhub_finding_aggregator": {
        "xoa_la_noi": "finding khong con gom ve mot region - phat hien o region khac thanh khong ai xem",
    },
    "aws_securityhub_organization_admin_account": {
        "xoa_la_noi": "go uy quyen quan tri Security Hub - moi thu o duoi phu thuoc vao no",
    },

    ####################################
    # config-detective - GuardDuty
    ####################################
    "aws_guardduty_detector": {
        "xoa_la_noi": "tat GuardDuty o mot account",
        "thuoc_tinh": {
            "enable": ("bool_phai_true", "GuardDuty bi tat"),
        },
    },
    "aws_guardduty_detector_feature": {
        "thuoc_tinh": {
            "status": ("thu_tu:ENABLED>DISABLED", "tat mot nguon du lieu cua GuardDuty - detector van 'dang bat' nen khong trong nhu co gi doi"),
        },
    },
    "aws_guardduty_organization_configuration": {
        "thuoc_tinh": {
            "auto_enable_organization_members": ("thu_tu:ALL>NEW>NONE", "thu hep tap account duoc tu bat GuardDuty - ALL sang NEW de lai nhung account DANG co ma khong bat"),
        },
    },
    "aws_guardduty_organization_configuration_feature": {
        "thuoc_tinh": {
            "auto_enable": ("thu_tu:ALL>NEW>NONE", "thu hep tap account duoc tu bat mot nguon du lieu"),
        },
    },
    "aws_guardduty_member": {
        "xoa_la_noi": "mot account khong con duoc GuardDuty theo doi",
    },
    "aws_guardduty_organization_admin_account": {
        "xoa_la_noi": "go uy quyen quan tri GuardDuty",
    },

    ####################################
    # config-detective - DUONG BAO DONG
    #
    # Phan nay de sot nhat, vi no khong phai "phep kiem" nen khong ai
    # nghi no la guardrail. Nhung mot phat hien khong den duoc voi ai
    # thi bang mot phat hien khong xay ra - va khac biet duy nhat la no
    # co trong bang dieu khien.
    ####################################
    "aws_sns_topic_subscription": {
        "xoa_la_noi": "mot nguoi nhan bao dong bien mat - phat hien van sinh ra, chi khong den voi ai",
    },
    "aws_cloudwatch_event_rule": {
        "xoa_la_noi": "phat hien khong con duoc chuyen di - Security Hub van day finding vao khoang khong",
        "thuoc_tinh": {
            "state": ("thu_tu:ENABLED>DISABLED", "rule bi tat"),
            "is_enabled": ("bool_phai_true", "rule bi tat (thuoc tinh cu)"),
        },
    },
    "aws_cloudwatch_event_target": {
        "xoa_la_noi": "rule con do nhung khong tro toi dau - day la kieu hong im lang nhat trong ca bang nay",
    },
    "aws_lambda_function": {
        "xoa_la_noi": "ham xu ly bao dong bien mat",
    },

    ####################################
    # org-trail  (chua vao pipeline - cho role lien account)
    #
    # Trail la thu duy nhat tra loi duoc "ai da lam gi". Moi dong duoi
    # day, khi bi noi, lam cau hoi do thanh khong tra loi duoc - va no
    # khong tra loi duoc VE QUA KHU, ke ca sau khi da sua lai.
    ####################################
    "aws_cloudtrail": {
        "xoa_la_noi": "khong con trail to chuc - khong con ban ghi ai lam gi",
        "thuoc_tinh": {
            "enable_logging":                ("bool_phai_true", "trail con do nhung khong ghi gi"),
            "include_global_service_events":  ("bool_phai_true", "mat su kien IAM, STS, CloudFront - dung nhung thu dung de leo quyen"),
            "is_multi_region_trail":          ("bool_phai_true", "chi con ghi mot region - hoat dong o region khac thanh vo hinh"),
            "is_organization_trail":         ("bool_phai_true", "thanh trail cua mot account thay vi ca to chuc"),
            "enable_log_file_validation":     ("bool_phai_true", "khong con phat hien duoc file log bi sua"),
        },
    },
    "aws_s3_bucket_object_lock_configuration": {
        "xoa_la_noi": "log co the bi xoa - object lock la thu khien ke xoa dau vet khong xoa duoc",
        "thuoc_tinh": {
            "rule.0.default_retention.0.days":  ("so_khong_giam", "giam so ngay giu log"),
            "rule.0.default_retention.0.years": ("so_khong_giam", "giam so nam giu log"),
            "rule.0.default_retention.0.mode":  ("bat_ky_doi", "doi che do object lock - GOVERNANCE co the bi bo qua boi nguoi co quyen, COMPLIANCE thi khong"),
        },
    },
    "aws_s3_bucket_public_access_block": {
        "xoa_la_noi": "bucket chua log co the thanh cong khai",
        "thuoc_tinh": {
            "block_public_acls":       ("bool_phai_true", "cho phep ACL cong khai"),
            "block_public_policy":     ("bool_phai_true", "cho phep bucket policy cong khai"),
            "ignore_public_acls":      ("bool_phai_true", "ngung bo qua ACL cong khai"),
            "restrict_public_buckets": ("bool_phai_true", "bo han che bucket cong khai"),
        },
    },
    "aws_s3_bucket_versioning": {
        "thuoc_tinh": {
            "versioning_configuration.0.status": ("chuoi_phai_la:Enabled", "tat versioning - ghi de mot file log khong con de lai ban cu"),
        },
    },

    ####################################
    # network/ops
    #
    # Layer nay da ton tai va DA tach state san - no la khuon mau cho
    # config-detective/ops va permission-sets/ops. Type doc tu chinh no:
    # vpn.tf:372 cho ingress rule, firewall.tf:209 cho rule group.
    ####################################
    "aws_vpc_security_group_ingress_rule": {
        # CHIEU NGUOC: tao mot ingress rule la MO mot cua.
        "tao_la_noi": "mo them mot duong vao - thay doi de nhat trong ca bang nay de bien mot mang kin thanh mang ho",
        "thuoc_tinh": {
            "cidr_ipv4": ("bat_ky_doi", "doi dai nguon duoc phep - rong hon la mo cho nhieu noi hon"),
            "from_port": ("bat_ky_doi", "doi khoang port"),
            "to_port":   ("bat_ky_doi", "doi khoang port"),
        },
    },
    "aws_networkfirewall_rule_group": {
        "xoa_la_noi": "bo mot nhom luat tuong lua - luu luong truoc day bi chan se di qua, va khong co log nao noi rang mot luat vua bien mat",
    },
    "aws_cloudwatch_metric_alarm": {
        "xoa_la_noi": "mot bao dong bien mat - su co van xay ra, chi khong ai biet",
    },
}
# fmt: on

########################################
# PHAM VI CUA TUNG STAGE
#
# Type nao KHONG co trong danh sach ma lai doi = tu choi. Day la chot
# chan cho TF_TARGETS rong, va no doc BAN PLAN chu khong doc bien.
########################################

# TACH STATE ops CHI O NOI TAN SO DOI BIEN MINH DUOC
#
#   Viec                            Catalog   State ops rieng
#   Config rule                     co        CO
#   Permission-set assignment       co        CO
#   Permission-set policy (noi dung) co       khong
#   SCP                             co        khong - sua tai cho
#   OU, CloudTrail                  khong     khong
#
# Vi sao khong tach het: mot state rieng la mot lan `terraform init`
# nua, mot khoa nua, va mot cho nua de lech. No chi tra duoc gia do khi
# thu do DOI HANG NGAY. SCP doi nhieu nhung no la MOT resource trong mot
# layer da co -target giu pham vi, nen tach state khong mua duoc gi.

# MOT MUC LA TYPE, HAY LA TIEN TO DIA CHI
#
# Co dau `.` -> tien to DIA CHI ("aws_organizations_policy.scp").
# Khong co   -> TYPE           ("aws_config_config_rule").
#
# Type khong co dau `.`, dia chi thi luon co, nen phep phan biet nay
# khong nhap nhang.
#
# VI SAO CAN CA HAI: mot layer co the co hai resource CUNG TYPE thuoc hai
# stage khac nhau. Layer organization la vi du that:
#
#   aws_organizations_policy.scp   SCP      -> stage SCP
#   aws_organizations_policy.tag   tag      -> stage tagging
#
# Cung type `aws_organizations_policy`. Khop theo type thi hai stage do
# co pham vi GIONG NHAU, tuc stage tagging duoc phep sua SCP va nguoc
# lai - dung cai ma pham_vi ton tai de chan.

# KHOA STAGE PHAI DUY NHAT TOAN CUC, VA MANG TEN CHU SO HUU
#
# Bang nay la MOT ban dung chung cho MOI pipeline van hanh. Ba pipeline
# duoc tach theo phong ban:
#
#   sec     landing-zone/organization          SCP, OU, tag policy
#   cloud   landing-zone/permission-sets/ops   ai vao account nao
#           landing-zone/config-detective/ops  Config rule
#           landing-zone/org-trail             CloudTrail
#   net     landing-zone/network/ops           DNS, endpoint, firewall
#
# Hai pipeline cung co mot stage ten "ou" se DE LEN NHAU trong bang nay,
# va cai bi de len se lang le nhan pham vi cua cai kia. Nen khoa mang
# tien to chu so huu.
#
# VA KHONG CON CHU CAI A/B/C. Thu tu chay do VI TRI trong danh sach
# stages_all quyet dinh (local.stages danh lai thu_tu tu dau) - chu cai
# chi la trang trai, va mot chu cai lech vi tri la dung cai bay cua loi
# 113 o dang khac.

PHAM_VI = {
    ####################################
    # sec - organization: MOT layer, MOT state, BA stage
    #
    # SCP, OU va tag policy nam cung mot layer va cung mot state. Chung
    # KHONG tach ra thanh ba layer: tach state la them hai lan init, hai
    # khoa, va hai cho de lech.
    #
    # Tach o day la tach PHAM VI, bang -target va bang bang nay.
    #
    # Thu tu chay: OU TRUOC SCP. Ly do do duoc: doi ten mot OU lam khoa
    # cua aws_organizations_policy_attachment.scp doi theo (khoa la
    # "<policy>|<ten OU>"), nen Terraform thay mot destroy + create -
    # tren cung mot OU id, tuc khong doi gi o AWS, nhung VAN la destroy.
    # FAIL_ON_DESTROY se chan no.
    #
    # Chan la dung. Dieu quan trong la chan trong CUNG mot luot chay:
    # neu SCP chay truoc OU thi OU doi xong va khong co gi doi chieu lai
    # attachment cho toi luot sau - state va cau hinh lech nhau trong im
    # lang suot khoang giua.
    ####################################
    "sec-ou": [
        "aws_organizations_organizational_unit.level1",
        "aws_organizations_organizational_unit.level2",
    ],

    "sec-scp": [
        "aws_organizations_policy.scp",
        "aws_organizations_policy_attachment.scp",
    ],

    "sec-tagging": [
        "aws_organizations_policy.tag",
        "aws_organizations_policy_attachment.tag",
    ],

    ####################################
    # config-detective/ops - state rieng
    #
    # Chi Config rule. Recorder, aggregator, Security Hub, GuardDuty
    # KHONG o day: chung doi vai lan mot nam, va mot pipeline tu apply
    # duoc chung la mot pipeline co the tat ca he thong phat hien cua to
    # chuc. Chung nam o layer cha, sua bang tay.
    ####################################
    "cloud-config-rules": [
        "aws_config_organization_managed_rule",
        "aws_config_config_rule",
    ],

    ####################################
    # permission-sets/ops - state rieng
    #
    # Chi AI VAO ACCOUNT NAO. Noi dung quyen (managed policy attachment,
    # inline policy) o layer cha: doi noi dung mot permission set la doi
    # quyen cua MOI nguoi dang dung set do, o MOI account, ngay lap tuc.
    # Do khong phai viec hang ngay.
    ####################################
    "cloud-permission-set": [
        "aws_ssoadmin_account_assignment",
        "aws_identitystore_group_membership",
    ],

    ####################################
    # network/ops - da co state rieng tu truoc
    ####################################
    "net-ops": [
        "aws_route53_record",
        "aws_vpc_endpoint",
        "aws_route53_zone",
        "aws_route53profiles_resource_association",
        "aws_networkfirewall_rule_group",
        "aws_ec2_transit_gateway_route",
        "aws_lb_target_group",
        "aws_lb_target_group_attachment",
        "aws_lb_listener",
        "aws_vpc_security_group_ingress_rule",
        "aws_vpn_connection_route",
        "aws_cloudwatch_metric_alarm",
    ],
}


def lay(d, duong_dan):
    """Doc mot thuoc tinh long nhau: "rule.0.default_retention.0.days".

    Tra ve (co_khong, gia_tri). PHAI tra ve ca co_khong: `None` va
    "khong co khoa nay" la hai viec khac nhau, va gop chung lai la dung
    cai khuyet diem ma ca file nay duoc viet ra de chan.
    """
    cur = d
    for k in duong_dan.split("."):
        if isinstance(cur, list):
            try:
                i = int(k)
            except ValueError:
                return False, None
            if i >= len(cur):
                return False, None
            cur = cur[i]
        elif isinstance(cur, dict):
            if k not in cur:
                return False, None
            cur = cur[k]
        else:
            return False, None
    return True, cur


def so(v):
    """Doi sang so, tra ve None neu khong phai so. 0 va None khac nhau."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return v
    return None


def kiem_thuoc_tinh(truoc, sau, duong_dan, kieu, vi_sao):
    """Tra ve ly do noi long, hoac None."""
    co_truoc, v_truoc = lay(truoc, duong_dan)
    co_sau, v_sau = lay(sau, duong_dan)

    # Chua co -> co: khong the la noi long. Co -> khong con: la noi
    # long, vi mot thuoc tinh bi bo se ve mac dinh cua AWS, va mac dinh
    # cua AWS gan nhu luon long hon.
    if not co_truoc and not co_sau:
        return None
    if not co_truoc:
        return None
    if not co_sau:
        return f"{duong_dan} BI BO khoi cau hinh (ve mac dinh cua AWS) - {vi_sao}"

    if kieu == "bool_phai_true":
        if v_truoc is True and v_sau is not True:
            return f"{duong_dan}: true -> {v_sau!r} - {vi_sao}"
        return None

    if kieu == "so_khong_giam":
        a, b = so(v_truoc), so(v_sau)
        if a is None or b is None:
            # Khong so sanh duoc thi PHAI noi ra, khong duoc im lang bo
            # qua: mot phep so hong tra ve "khong co gi" doc giong het
            # "khong co thay doi".
            if v_truoc != v_sau:
                return f"{duong_dan}: {v_truoc!r} -> {v_sau!r}, khong so sanh duoc nhu so - {vi_sao}"
            return None
        if b < a:
            return f"{duong_dan}: {a} -> {b} (giam) - {vi_sao}"
        return None

    if kieu.startswith("chuoi_phai_la:"):
        can = kieu.split(":", 1)[1]
        if v_truoc == can and v_sau != can:
            return f"{duong_dan}: {can!r} -> {v_sau!r} - {vi_sao}"
        return None

    # "thu_tu:ALL>NEW>NONE" - gia tri khong duoc di xuong trong bang xep.
    #
    # Can rieng kieu nay vi phep so chuoi noi nguoc: "NONE" > "ALL" theo
    # thu tu chu cai, nen so sanh chuoi thong thuong se coi viec tat
    # GuardDuty la mot buoc THAT.
    if kieu.startswith("thu_tu:"):
        bang = kieu.split(":", 1)[1].split(">")
        if v_truoc not in bang or v_sau not in bang:
            # Mot gia tri ngoai bang: khong ket luan duoc. PHAI noi ra.
            if v_truoc != v_sau:
                return (
                    f"{duong_dan}: {v_truoc!r} -> {v_sau!r}, co gia tri ngoai bang "
                    f"xep {'>'.join(bang)} nen KHONG xep duoc chieu - {vi_sao}"
                )
            return None
        if bang.index(v_sau) > bang.index(v_truoc):
            return f"{duong_dan}: {v_truoc} -> {v_sau} - {vi_sao}"
        return None

    # Tap hop LON LEN la noi long. Dung cho excluded_accounts va nhung
    # danh sach mien tru khac, noi moi phan tu them vao la mot thu thoat
    # khoi phep kiem.
    if kieu == "tap_khong_lon":
        t = set(v_truoc or []) if isinstance(v_truoc, (list, set)) else set()
        s = set(v_sau or []) if isinstance(v_sau, (list, set)) else set()
        if not isinstance(v_sau, (list, set)) and v_sau is not None:
            return f"{duong_dan}: {v_sau!r} khong phai danh sach, khong so sanh duoc - {vi_sao}"
        them = s - t
        if them:
            return f"{duong_dan} THEM {', '.join(sorted(str(x) for x in them))} - {vi_sao}"
        return None

    if kieu == "bat_ky_doi":
        if v_truoc != v_sau:
            return f"{duong_dan} doi - {vi_sao}"
        return None

    # Kieu luat khong biet: KHONG duoc coi la dat. Mot go sai ten kieu
    # se lam ca luat do bien mat trong im lang.
    return f"{duong_dan}: KIEU LUAT KHONG BIET {kieu!r} - luat nay chua duoc thi hanh"


def phan_loai(rc):
    """Tra ve danh sach ly do noi long cua mot resource_change."""
    hanh_dong = rc["change"]["actions"]
    if hanh_dong == ["no-op"] or hanh_dong == ["read"]:
        return []

    luat = LUAT.get(rc["type"])
    if luat is None:
        return []

    truoc = rc["change"].get("before") or {}
    sau = rc["change"].get("after") or {}
    ly_do = []

    xoa = "delete" in hanh_dong
    tao = "create" in hanh_dong
    thay_the = xoa and tao

    # Thay the = xoa roi tao lai. Voi guardrail, giua hai buoc do co mot
    # khoang thoi gian KHONG CO lop chan - nen thay the luon phai khai
    # bao, ke ca khi ket qua cuoi giong het ban dau.
    if thay_the:
        ly_do.append(
            "THAY THE (xoa roi tao lai): co mot khoang thoi gian resource nay khong ton tai. "
            + (luat.get("xoa_la_noi") or luat.get("tao_la_noi") or "")
        )
    elif xoa and "xoa_la_noi" in luat:
        ly_do.append("XOA: " + luat["xoa_la_noi"])
    elif tao and "tao_la_noi" in luat:
        ly_do.append("TAO: " + luat["tao_la_noi"])

    if "update" in hanh_dong or thay_the:
        for duong_dan, (kieu, vi_sao) in (luat.get("thuoc_tinh") or {}).items():
            r = kiem_thuoc_tinh(truoc, sau, duong_dan, kieu, vi_sao)
            if r:
                ly_do.append(r)

    return ly_do


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True, help="file tfplan.json tu `terraform show -json`")
    ap.add_argument("--layer", required=True)
    ap.add_argument("--stage", required=True)
    ap.add_argument("--loosen", default="", help="YAML khai bao noi long co chu dich")
    ap.add_argument("--strict", action="store_true", help="canh bao thanh loi")
    a = ap.parse_args()

    if not os.path.exists(a.plan):
        print(f"  {R}KHONG thay {a.plan}{N}")
        print("    Cong nay chay SAU `terraform show -json <file plan> > tfplan.json`.")
        print("    Day KHONG phai 'khong co thay doi' - la CHUA DOC DUOC.")
        return 1

    try:
        with open(a.plan) as f:
            plan = json.load(f)
    except json.JSONDecodeError as e:
        print(f"  {R}{a.plan} khong phai JSON hop le{N}: {e}")
        return 1

    rcs = plan.get("resource_changes")

    ####################################
    # CHOT CHAN: RONG KHONG PHAI "KHONG CO THAY DOI"
    #
    # Do tren ban plan that cua layer organization: mot plan KHONG co
    # thay doi nao van chua DU 25 muc, moi muc actions = ["no-op"].
    # Terraform khong bo chung ra.
    #
    # Nen resource_changes rong nghia la mot trong nhung viec sau, va
    # khong viec nao la "sach": sai file, plan cua layer khac, hoac mot
    # phien ban Terraform doi cach bieu dien. Ca ba deu phai dung.
    ####################################
    if not rcs:
        print(f"  {R}resource_changes RONG trong {a.plan}{N}")
        print(f"    format_version = {plan.get('format_version')!r}")
        print("    Mot plan khong co thay doi van liet ke DU moi resource voi")
        print("    actions = [\"no-op\"] - do tren ban plan that cua layer")
        print("    organization: 25 muc. Nen rong KHONG phai 'khong co gi noi',")
        print("    la CHUA DOC DUOC: sai file, plan cua layer khac, hoac dinh")
        print("    dang doi.")
        return 1

    ####################################
    # KHAI BAO NOI LONG
    ####################################
    khai = {}
    if a.loosen and os.path.exists(a.loosen):
        try:
            import yaml
        except ImportError:
            print(f"  {R}can PyYAML de doc {a.loosen}{N}")
            return 1
        with open(a.loosen) as f:
            doc = yaml.safe_load(f) or {}
        for m in doc.get("loosen") or []:
            if "address" in m:
                khai[m["address"]] = m

    ####################################
    # PHAM VI
    ####################################
    pham_vi = PHAM_VI.get(a.stage)
    doi = [r for r in rcs if r["change"]["actions"] not in (["no-op"], ["read"])]

    loi = []
    canh_bao = []

    if pham_vi is None:
        canh_bao.append(
            f"stage {a.stage!r} khong co trong bang PHAM_VI - cong nay khong "
            "kiem duoc pham vi cho no. Them vao gate.py."
        )
    else:
        # Tach bang thanh hai tap: type va tien to dia chi. Xem chu thich
        # dau bang PHAM_VI.
        cho_type = {p for p in pham_vi if "." not in p}
        cho_dia_chi = tuple(p for p in pham_vi if "." in p)

        def trong_pham_vi(r):
            if r["type"] in cho_type:
                return True
            return bool(cho_dia_chi) and r["address"].startswith(cho_dia_chi)

        # Bao theo DIA CHI, khong theo type: hai resource cung type ma
        # khac stage thi mot thong bao noi ten type khong chi duoc ra cai
        # nao dang ngoai pham vi.
        ngoai = sorted({r["address"] for r in doi if not trong_pham_vi(r)})
        if ngoai:
            loi.append(
                f"{R}NGOAI PHAM VI{N} cua stage {a.stage}: {', '.join(ngoai)}. "
                f"Stage nay chi duoc doi {', '.join(pham_vi)}. "
                "Nguyen nhan hay gap nhat la TF_TARGETS rong hoac go sai ten "
                "resource - `terraform plan` KHONG bao loi cho viec do, no chi "
                "plan CA layer."
            )

    ####################################
    # PHAN LOAI
    ####################################
    noi_long = []
    for r in doi:
        for ly_do in phan_loai(r):
            noi_long.append((r["address"], ly_do))

    print()
    print(f"  Cong van hanh: {a.layer}  stage {a.stage}")
    print(f"  {len(rcs)} resource trong ban plan, {len(doi)} co thay doi")
    print()

    for r in doi:
        print(f"    {'+'.join(r['change']['actions']):<14} {r['address']}")
    if doi:
        print()

    for dia_chi, ly_do in noi_long:
        m = khai.get(dia_chi)
        if not m:
            loi.append(f"{R}NOI ma khong khai bao{N}: {dia_chi}\n        {ly_do}")
            continue
        thieu = [k for k in ("ticket", "reason", "approved_by") if not m.get(k)]
        if thieu:
            loi.append(
                f"{R}Khai bao noi long thieu truong{N} {', '.join(thieu)}: {dia_chi}"
            )
            continue
        print(f"  {Y}NOI co khai bao{N}: {dia_chi}")
        print(f"      {ly_do}")
        print(f"      ticket {m['ticket']} - {m['reason']} - duyet boi {m['approved_by']}")

    ####################################
    # KHAI BAO KHONG DUNG TOI
    #
    # Mot khai bao con lai sau khi thay doi da di qua la mot cua mo bo
    # ngo: lan sau co nguoi noi long dung dia chi do se khong bi chan.
    ####################################
    khong_dung = sorted(set(khai) - {d for d, _ in noi_long})
    for dia_chi in khong_dung:
        canh_bao.append(
            f"khai bao noi long cho {dia_chi} KHONG dung toi - ban plan khong "
            "noi long o day. Xoa no di: mot khai bao con lai la mot cua mo bo "
            "ngo cho lan sau."
        )

    print()
    for c in canh_bao:
        print(f"  {Y}CANH BAO{N} {c}")
    for l in loi:
        print(f"  {R}LOI{N}  {l}")

    print()
    if loi or (a.strict and canh_bao):
        print(f"  {R}{len(loi)} loi, {len(canh_bao)} canh bao{N}")
        print("  Noi long phai co khoi `loosen` trong file khai bao, voi")
        print("  ticket / reason / approved_by - de no hien ra trong diff cua PR.")
        return 1

    print(f"  {G}Khong co noi long nao chua khai bao.{N} {len(canh_bao)} canh bao.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
