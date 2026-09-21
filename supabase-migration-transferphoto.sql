-- =========================================================
-- 본노엘 운영 앱: 점간 이동에 사진 첨부(선택) 추가
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

alter table ops_transfers add column if not exists photo_path text;
