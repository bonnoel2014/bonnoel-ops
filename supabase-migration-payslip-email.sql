-- =========================================================
-- 명세서 이메일 발송 기록 컬럼 추가
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

alter table ops_pay_runs add column if not exists email_to text;
alter table ops_pay_runs add column if not exists email_sent_at timestamptz;
alter table ops_pay_runs add column if not exists email_error text;
