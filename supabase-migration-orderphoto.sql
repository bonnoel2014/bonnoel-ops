-- =========================================================
-- 본노엘 운영 앱: 비품 주문에 주문 캡쳐(사진) 첨부
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

alter table ops_orders add column if not exists photo_path text;
