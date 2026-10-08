-- =========================================================
-- 본노엘 운영 앱: 비품 체크에 '지하 재고' 칸 + 매주 '비품리스트 표(종이 양식)' 기록
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

-- 지하 재고 (비품 체크 때 같이 적음 · 부족 계산에는 안 넣고 표에만 보여줘요)
alter table ops_stock_checks add column if not exists basement_qty numeric;

-- 매주 표 기록 (매장·주마다 한 장, 같은 주에 다시 저장하면 덮어씀)
create table if not exists ops_weekly_sheets (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  week_start date not null,
  rows jsonb not null default '[]'::jsonb,
  made_by uuid references manual_staff(id) on delete set null,
  made_at timestamptz not null default now(),
  unique (branch_id, week_start)
);
create index if not exists ops_weekly_sheets_branch_idx on ops_weekly_sheets (branch_id, week_start desc);

alter table ops_weekly_sheets enable row level security;
drop policy if exists "anon full access" on ops_weekly_sheets;
create policy "anon full access" on ops_weekly_sheets for all using (true) with check (true);
