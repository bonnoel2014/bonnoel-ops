-- =========================================================
-- 매장 나열 순서를 오픈 연도 순(성수 → 답십리 → 중계 → 왕십리)으로 통일
-- 앱 안의 모든 매장 목록·탭·드롭다운은 manual_branches.sort_order 순서를 그대로 따르므로,
-- 이 값만 바꾸면 앱 전체(매장 탭, 근무표, 비품, 직원 구매 등)에 자동으로 반영됩니다.
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================
update manual_branches set sort_order = 1 where name = '성수점';
update manual_branches set sort_order = 2 where name = '답십리점';
update manual_branches set sort_order = 3 where name = '중계점';
update manual_branches set sort_order = 4 where name = '왕십리점';
