-- =========================================================
-- 본노엘 운영 앱: 마감·오픈 체크리스트 (매장폰에서 알바가 체크 → 이름 고르고 제출)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 매장 하나 + 하루 + 체크리스트 하나 = 한 줄 (체크하는 동안은 draft, 제출하면 submitted)
create table if not exists ops_checklist_runs (
  id uuid primary key default gen_random_uuid(),
  run_date date not null,                                            -- 근무한 날
  branch_id uuid references manual_branches(id) on delete cascade,   -- 매장
  list_key text not null default 'main',                             -- 체크리스트 종류 (지금은 매장당 1개)
  checked jsonb not null default '{}'::jsonb,                        -- {"0-3": true, ...} 체크한 항목
  memo text,                                                         -- 전달 사항
  total int not null default 0,                                      -- 전체 항목 수
  done int not null default 0,                                       -- 체크한 수
  missing jsonb not null default '[]'::jsonb,                        -- 제출 때 못 한 항목 이름들
  status text not null default 'draft',                              -- draft(체크 중) / submitted(제출함)
  staff_id uuid references manual_staff(id) on delete set null,      -- 제출한 사람(작성인)
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ops_checklist_runs_one_idx on ops_checklist_runs (run_date, branch_id, list_key);
create index if not exists ops_checklist_runs_date_idx on ops_checklist_runs (run_date);

alter table ops_checklist_runs enable row level security;
drop policy if exists "anon full access" on ops_checklist_runs;
create policy "anon full access" on ops_checklist_runs for all using (true) with check (true);
