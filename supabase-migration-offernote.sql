-- =========================================================
-- 본노엘 운영 앱: 대타 지원할 때 "가능한 시간"·"특이사항" 적기
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

alter table ops_sub_offers add column if not exists note text;           -- 특이사항 (예: 16시까지만 가능해요)
alter table ops_sub_offers add column if not exists avail_start time;    -- 가능한 시작 (요청 시간보다 짧게 가능할 때만)
alter table ops_sub_offers add column if not exists avail_end time;      -- 가능한 끝
