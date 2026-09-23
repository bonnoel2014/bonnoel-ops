-- =========================================================
-- 본노엘 운영 앱 13차: 매니저·사장님이 임의로 대타(추가 자리) 구하기
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 기존 근무자의 "휴무 신청"이 아니라, 매니저·사장님이 필요해서 새로 만드는 자리도 올릴 수 있게
-- staff_id를 비워 둘 수 있게 함(비어 있으면 "원래 근무자 없는 추가 자리"라는 뜻)
alter table ops_leave_requests alter column staff_id drop not null;
alter table ops_leave_requests add column if not exists created_by uuid references manual_staff(id) on delete set null;  -- 이 자리를 올린 사람(매니저·사장님)
