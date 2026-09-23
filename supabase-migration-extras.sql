-- =========================================================
-- 본노엘 운영 앱 12차: 출퇴근 근무표 기준 처리 + 추가 근무 승인
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- 설계: 기획/출퇴근_근무표기준_설계.md
-- =========================================================

-- 1. 출퇴근 기록에 "그때의 근무표 칸" 복사본 (clock_in/clock_out은 실제 누른 시각으로 그대로 보관)
alter table ops_attendance add column if not exists sched_start time;          -- 근무표 시작 (null이면 옛 방식 = 실제 시각 기준)
alter table ops_attendance add column if not exists sched_end time;            -- 근무표 끝
alter table ops_attendance add column if not exists sched_break_min int;       -- 근무표 휴게(분)
alter table ops_attendance add column if not exists no_schedule boolean not null default false;  -- 근무표에 없는 날 출근

-- 2. 추가 근무 (직원이 사유와 함께 올리고 사장님이 수락해야 인정)
create table if not exists ops_attendance_extras (
  id uuid primary key default gen_random_uuid(),
  attendance_id uuid references ops_attendance(id) on delete cascade,
  staff_id uuid not null references manual_staff(id) on delete cascade,
  branch_id uuid references manual_branches(id) on delete set null,
  work_date date not null,
  kind text not null default 'late',            -- early(조기 출근) / late(연장) / other(기타)
  start_at timestamptz,
  end_at timestamptz,
  minutes int not null,                         -- 올린 분 (5분 단위)
  reason text not null,
  status text not null default 'requested',     -- requested / approved / rejected
  approved_minutes int,                         -- 시간 고쳐서 수락한 경우 (null이면 minutes 그대로)
  reject_reason text,
  decided_by uuid references manual_staff(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists ops_attendance_extras_branch_date_idx on ops_attendance_extras (branch_id, work_date);
create index if not exists ops_attendance_extras_staff_idx on ops_attendance_extras (staff_id, work_date);
create index if not exists ops_attendance_extras_status_idx on ops_attendance_extras (status);

alter table ops_attendance_extras enable row level security;
drop policy if exists "anon full access" on ops_attendance_extras;
create policy "anon full access" on ops_attendance_extras for all using (true) with check (true);

-- 3. 빠진 출퇴근 "근무표대로 채우기" (9/23 추가)
--    직원 본인이 채우면 requested(사장님 수락 대기, 수락 전엔 인정 0), 매니저·사장님이 채우면 바로 approved
--    approved면 근무표 시간 전체 인정(지각 차감 없음). 실제 누른 시각이 있으면 clock_in/out에 그대로 남음
alter table ops_attendance add column if not exists fill_status text;          -- null(보통) / requested / approved / rejected
alter table ops_attendance add column if not exists filled_by uuid references manual_staff(id) on delete set null;
alter table ops_attendance add column if not exists filled_at timestamptz;
