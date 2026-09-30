-- =========================================================
-- 직원 구매 추가: 영수증 사진 최대 3장 (첫 장은 photo_path, 2·3번째 장은 여기에 목록으로)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- staffbuy3(결제 증빙 칸)도 아직 안 돌렸으면 같이 실행돼요.
-- =========================================================
alter table ops_staff_purchases add column if not exists pay_proof_path text;
alter table ops_staff_purchases add column if not exists extra_photo_paths jsonb;
