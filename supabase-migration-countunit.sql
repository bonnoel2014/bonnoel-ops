-- =========================================================
-- 본노엘 운영 앱: 비품 체크에 α(세기 어려움/충분) 입력, 세기 쉬운 단위 환산(예: 2박스=1묶음) 추가
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

-- 비품 체크에서 그날 "충분해서 못 셌어요(α)"로 기록한 건지 표시
alter table ops_stock_checks add column if not exists unlimited boolean not null default false;

-- 세기 쉬운 다른 단위로 넣으면 자동으로 적정재고 단위로 환산 (예: count_unit='박스', count_per_unit=2 → 박스 2개 = 기본 단위 1개)
alter table ops_items add column if not exists count_unit text;
alter table ops_items add column if not exists count_per_unit numeric;
