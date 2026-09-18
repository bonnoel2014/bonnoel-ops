-- =========================================================
-- 본노엘 운영 앱 2차: 휴무·대타·근무표 - 테이블 추가
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만)
-- supabase-setup.sql 이 먼저 실행된 상태여야 합니다.
-- =========================================================

-- 1. 근무 패턴: 사람마다 고정 요일·시간 (예: 수·목·금 16:30~21:00). weekday: 0=일 1=월 … 6=토
create table if not exists ops_shift_patterns (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references manual_staff(id) on delete cascade,
  branch_id uuid not null references manual_branches(id) on delete cascade,
  weekday int not null check (weekday between 0 and 6),
  start_time text not null,        -- 'HH:MM'
  end_time text not null,
  break_start text,                -- 휴게 (없으면 null)
  break_end text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists ops_shift_patterns_branch_idx on ops_shift_patterns (branch_id, weekday);

-- 2. 휴무 신청 (한 근무 한 건)
--    status: requested(신청) / rejected(거절) / covering(수락됨·대타 구하는 중) / confirmed(대타 확정 또는 1인 근무 휴무) / cancelled(취소)
create table if not exists ops_leave_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references manual_staff(id) on delete cascade,
  branch_id uuid not null references manual_branches(id) on delete cascade,
  date date not null,
  start_time text not null,
  end_time text not null,
  reason text,
  status text not null default 'requested',
  decided_by uuid references manual_staff(id) on delete set null,
  decided_at timestamptz,
  sub_staff_id uuid references manual_staff(id) on delete set null,   -- 확정된 대타 (없이 확정이면 1인 근무 휴무)
  solo_ok_by uuid references manual_staff(id) on delete set null,     -- 파트너가 "그날 혼자 가능" 누름
  confirmed_by uuid references manual_staff(id) on delete set null,
  confirmed_at timestamptz,
  memo text,
  created_at timestamptz not null default now()
);
create index if not exists ops_leave_requests_branch_date_idx on ops_leave_requests (branch_id, date);

-- 3. 대타 지원
create table if not exists ops_sub_offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references ops_leave_requests(id) on delete cascade,
  staff_id uuid not null references manual_staff(id) on delete cascade,
  status text not null default 'offered',   -- offered / confirmed / passed
  created_at timestamptz not null default now(),
  unique (request_id, staff_id)
);

alter table ops_shift_patterns enable row level security;
alter table ops_leave_requests enable row level security;
alter table ops_sub_offers enable row level security;
drop policy if exists "anon full access" on ops_shift_patterns;
create policy "anon full access" on ops_shift_patterns for all using (true) with check (true);
drop policy if exists "anon full access" on ops_leave_requests;
create policy "anon full access" on ops_leave_requests for all using (true) with check (true);
drop policy if exists "anon full access" on ops_sub_offers;
create policy "anon full access" on ops_sub_offers for all using (true) with check (true);
