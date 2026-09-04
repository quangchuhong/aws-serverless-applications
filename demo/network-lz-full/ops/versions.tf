########################################
# LOP VAN HANH MANG - state RIENG
#
# Layer cha (../) so huu TGW, security VPC, firewall, va moi VPC.
# No doi vai thang mot nam.
#
# Layer nay so huu bon thu doi HANG NGAY:
#
#   1. Rule firewall east-west   ai duoc goi ai, port nao
#   2. Route ngoai le trong TGW  blackhole, duong toi doi tac
#   3. Interface endpoint        them/bot dich vu AWS tap trung
#   4. Ban ghi DNS noi bo        ten trong PHZ tap trung
#
# TACH LAM HAI STATE LA CA THIET KE, khong phai cho gon file.
#
# Gop chung thi mo mot port la mot `terraform plan` cham vao hon 200
# resource: firewall, NAT, moi subnet, moi stack instance cross-account.
# Nguoi duyet phai doc het de biet plan do KHONG lam gi khac ngoai
# them mot dong rule. Lam vay moi ngay thi khong ai doc that, va den
# mot ngay co nguoi bam yes qua nhanh - dung luc plan do chua mot
# thay doi khong ai de y.
#
# Tach ra thi plan cua lop nay cham vao dung 4 loai resource. Kich ban
# xau nhat cua mot lan apply sai o day la mot rule sai hoac mot ban
# ghi DNS sai - sua bang mot commit. Khong lan nao cham duoc vao
# firewall endpoint hay route mac dinh, vi chung khong nam trong state
# nay.
#
# DOI LAI: hai lop phai khop nhau o MOT diem - var.ops_rule_group_arns
# ben layer cha. Xem README.md muc "Bootstrap".
########################################

terraform {
  required_version = ">= 1.5.0"

  ########################################
  # BACKEND CUA CHINH LOP NAY
  #
  # Mac dinh: state local. Dung cho demo, du cho mot nguoi chay.
  #
  # Layer cha dung backend tu xa thi lop nay PHAI theo. Ly do khong
  # phai cho dong bo cho dep: state cua lop nay giu ARN cua rule group
  # ma firewall policy dang tham chieu. Mat file do la mat quyen sua
  # va quyen xoa mot resource van dang chay - Terraform se doi tao
  # rule group thu hai, con cai cu nam lai vinh vien khong ai quan.
  #
  # Va khi hai nguoi cung sua catalog, state local nghia la khong co
  # khoa: hai lan apply song song, nguoi sau ghi de rule cua nguoi
  # truoc, khong ben nao thay diff.
  #
  # KEY PHAI NAM DUOI DUNG PREFIX MA ACCOUNT NAY DUOC CAP.
  #
  # Bucket state cua landing-zone/tf-backend cap quyen THEO PREFIX,
  # moi account mot prefix rieng (var.state_writer_accounts):
  #
  #   s3:ListBucket  tren bucket, dieu kien s3:prefix = "<ten>/*"
  #   s3:GetObject   tren "<bucket>/<ten>/*"
  #   s3:PutObject   tren "<bucket>/<ten>/*"
  #
  # Nghia la key cua lop nay phai bat dau bang CUNG prefix voi key
  # cua layer cha. Dat mot prefix moi (vi du "network-ops/") thi
  # khong co mot dong Allow nao phu, va S3 tra ve:
  #
  #   Error refreshing state: ... HeadObject ... StatusCode: 403
  #   api error Forbidden: Forbidden
  #
  # 403 chu KHONG phai 404, du object chua he ton tai - vi khong co
  # quyen ListBucket tren prefix do thi S3 khong duoc phep tiet lo ca
  # viec object co ton tai hay khong. Va 403 doc nhu "sai credential",
  # nen cho dau tien ai cung di kiem la vai tro va profile.
  #
  # DUNG GO KHOI NAY BANG TAY. Chay:
  #
  #   ./backend-hint.sh
  #
  # No doc cau hinh ma `terraform init` cua layer cha da ghi ra, in lai
  # NGUYEN VEN, va chi doi mot thu: key -> cung thu muc + "ops/".
  #
  # Go tay hong o hai cho, va ca hai deu ra cung mot loi 403:
  #
  #   1. Doan prefix. Prefix la mot chuoi tu dat luc dung tf-backend,
  #      khong suy ra duoc tu ten layer hay ten account. "network/"
  #      nghe hop ly va van sai neu that ra la "demo-network-lz-full/".
  #
  #   2. Bo sot dong. Cau hinh backend co the mang profile, role_arn,
  #      assume_role, dynamodb_table. Thieu profile/role_arn thi lop
  #      nay goi S3 bang MOT DANH TINH KHAC layer cha - cung bucket,
  #      cung vung, khac nguoi goi - va 403 do khong lien quan gi toi
  #      key.
  #
  # Cach khac: them mot prefix rieng vao state_writer_accounts ben
  # landing-zone/tf-backend roi apply layer do. Chay duoc, nhung phai
  # sua mot layer DUNG CHUNG cho ca to chuc chi de doi cho de mot file
  # - va no pha vo bat bien "mot account, mot prefix" cua thiet ke do.
  ########################################

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # >= 5.60 de co aws_route53profiles_* - endpoint moi phai duoc
      # gan vao Profile, neu khong thi account khac khong phan giai
      # duoc ten dich vu vua them.
      version = ">= 5.60, < 6.0"
    }
  }
}

provider "aws" {
  region = local.hub.region

  # Profile de TAO RESOURCE - khac profile trong khoi backend o tren.
  #
  # Backend noi state nam o dau (co the la account management). Dong
  # nay noi ha tang duoc tao o dau (account network). Gop hai thu do
  # lam mot la cach chac chan nhat de mot ngay nao do rule group xuat
  # hien trong account chua bucket state.
  #
  # De trong = dung chuoi giai credential mac dinh. Nho rang BIEN MOI
  # TRUONG DUNG TRUOC profile trong chuoi do: co AWS_ACCESS_KEY_ID
  # trong shell thi dong nay bi bo qua ma khong co gi bao.
  #
  # Precondition trong main.tf doi chieu account thuc te voi account
  # ghi trong state cua layer cha, nen lech la plan dung lai.
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      Project   = local.hub.project
      ManagedBy = "terraform"
      Repo      = "aws-serverless-applications/demo/network-lz-full/ops"

      # Phan biet voi resource cua layer cha khi doc Cost Explorer hay
      # khi quet tag luc go bo.
      Layer = "network-ops"
    }
  }
}
