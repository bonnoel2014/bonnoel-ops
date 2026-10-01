-- =========================================================
-- 본노엘 운영 앱: 품목 메모를 매장별로 따로 쓰게 변경
-- (전에는 메모가 품목 하나에 전체 매장 공통이라, 한 매장에서 쓴 메모가 다른 매장에도 그대로 보였어요)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

alter table ops_item_branch add column if not exists note text;

-- 기존에 품목에 적어둔 메모를, 그 품목을 쓰는 매장 전부에 한 번 복사해 둡니다.
-- (어느 매장 얘기였는지 구분이 안 돼서 일단 전부에 넣어두고, 필요 없는 매장은 각자 메모에서 지우면 돼요)
update ops_item_branch ib
set note = oi.note
from ops_items oi
where ib.item_id = oi.id and oi.note is not null and ib.note is null;
