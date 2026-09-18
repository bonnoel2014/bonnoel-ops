-- =========================================================
-- 본노엘 운영 앱 2-2차: 특정 주 근무표 + 코멘트 칸
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만)
-- =========================================================

-- 1. 근무 패턴에 "어느 주 전용인지" (비어 있으면 매주 같은 고정 패턴)
alter table ops_shift_patterns add column if not exists week_start date;
create index if not exists ops_shift_patterns_week_idx on ops_shift_patterns (branch_id, week_start);

-- 2. 사람마다 코멘트 (예: 목 오픈 고정 > 수 오픈+미들 고정)
alter table manual_staff add column if not exists memo text;

-- 3. 매장 메모 (입사 예정·퇴사 예정·충원 예정 등)
create table if not exists ops_branch_notes (
  branch_id uuid primary key references manual_branches(id) on delete cascade,
  text text not null default '',
  updated_by uuid references manual_staff(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table ops_branch_notes enable row level security;
drop policy if exists "anon full access" on ops_branch_notes;
create policy "anon full access" on ops_branch_notes for all using (true) with check (true);

-- =========================================================
-- 4. 출퇴근 기록 (매장폰에서 이름·비밀번호로 출근/퇴근)
-- =========================================================
create table if not exists ops_attendance (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references manual_staff(id) on delete cascade,
  branch_id uuid not null references manual_branches(id) on delete cascade,
  work_date date not null,                  -- 출근한 날짜
  clock_in timestamptz,
  clock_out timestamptz,
  in_by uuid references manual_staff(id) on delete set null,     -- 본인이면 본인, 매니저가 넣으면 매니저
  out_by uuid references manual_staff(id) on delete set null,
  memo text,
  edits jsonb not null default '[]',        -- [{at, by, field, from, to, reason}]
  created_at timestamptz not null default now()
);
create index if not exists ops_attendance_branch_date_idx on ops_attendance (branch_id, work_date);
create index if not exists ops_attendance_staff_date_idx on ops_attendance (staff_id, work_date);
alter table ops_attendance enable row level security;
drop policy if exists "anon full access" on ops_attendance;
create policy "anon full access" on ops_attendance for all using (true) with check (true);
