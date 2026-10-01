-- =========================================================
-- 본노엘 운영 앱: "일시 품절" 메모는 7일 지나면 자동으로 사라지게
-- (직접 쓴 메모는 그대로 남아있고, 원클릭 "일시 품절" 버튼으로 쓴 것만 자동 만료됨)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

alter table ops_item_branch add column if not exists note_at timestamptz;
alter table ops_item_branch add column if not exists note_temp boolean not null default false;
