########################################
# CANH BAO KHI DANG MO KHOA
#
# allow_destroy = true la trang thai TAM THOI, chi dung trong lan
# teardown. De sot lai thi ha tang thuong tru dang khong con lop
# chan nao - va khong co gi trong terraform plan nhac ban ca.
#
# check khong lam plan that bai, chi in canh bao. Co chu dich:
# giua lan apply "mo khoa" va lan destroy, plan PHAI chay duoc.
########################################

check "destroy_guard_still_on" {
  assert {
    condition     = !var.allow_destroy
    error_message = "allow_destroy = true: bucket state va bucket log dang o che do force_destroy, mot lan destroy la mat state cua MOI layer. Dung neu dang teardown. Xong viec - hoac neu doi y - dat lai false va apply."
  }
}
