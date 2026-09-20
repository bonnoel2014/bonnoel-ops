-- =========================================================
-- 직원 구매 추가: 실제 구매한 사람 이름(앱에 등록 안 된 베이커 등도 가능) + 누가 입력했는지
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================
alter table ops_staff_purchases add column if not exists buyer_name text;   -- 사장님이 대신 넣을 때 이름을 직접 씀 (등록 안 된 사람도 가능)
alter table ops_staff_purchases add column if not exists entered_by uuid references manual_staff(id) on delete set null;   -- 실제로 앱에 입력한 사람 (본인이면 구매자와 같음)
