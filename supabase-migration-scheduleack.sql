-- =========================================================
-- 근무표 확인: 알바생이 이번 주 스케줄을 봤다고 표시, 사장님/매니저는 누가 안 봤는지 확인
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만)
-- =========================================================

create table if not exists ops_schedule_acks (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  staff_id uuid not null references manual_staff(id) on delete cascade,
  week_start date not null,
  acked_at timestamptz not null default now(),
  unique (branch_id, staff_id, week_start)
);
create index if not exists ops_schedule_acks_branch_week_idx on ops_schedule_acks (branch_id, week_start);

alter table ops_schedule_acks enable row level security;
drop policy if exists "anon full access" on ops_schedule_acks;
create policy "anon full access" on ops_schedule_acks for all using (true) with check (true);
