-- =========================================================
-- 본노엘 운영 앱: 품목 α(무제한/카운트 어려움) 표시
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

-- 재고가 항상 넉넉해서 세기 어려운 품목에 표시. 켜두면 부족·주문 목록에서 빠집니다.
alter table ops_items add column if not exists unlimited boolean not null default false;
