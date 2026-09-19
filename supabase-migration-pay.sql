-- =========================================================
-- 본노엘 운영 앱 4차: 급여 초안·명세서
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만)
-- =========================================================

-- 1. 사람별 급여 설정 (시급·고용형태·부양가족·이메일)
create table if not exists ops_pay_profiles (
  staff_id uuid primary key references manual_staff(id) on delete cascade,
  hourly_wage numeric not null default 0,
  pay_type text not null default 'insured',   -- insured(4대보험) / freelance(3.3%)
  dependents int not null default 1,          -- 본인 포함 부양가족 수 (간이세액표용)
  email text,
  memo text,
  updated_at timestamptz not null default now()
);

-- 2. 요율 등 설정 (한 줄, key='pay')
create table if not exists ops_settings (
  key text primary key,
  value jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

-- 3. 월별 급여 초안 (사람·매장·월 하나에 한 줄)
create table if not exists ops_pay_runs (
  id uuid primary key default gen_random_uuid(),
  ym text not null,                    -- '2026-09'
  branch_id uuid not null references manual_branches(id) on delete cascade,
  staff_id uuid not null references manual_staff(id) on delete cascade,
  data jsonb not null default '{}',    -- 계산 결과 전체
  income_tax numeric,                  -- 근로소득세 (간이세액표 값을 사람이 넣음, 없으면 0)
  adjust numeric not null default 0,   -- 조정액 (+/-)
  adjust_memo text,
  pay_date date,
  status text not null default 'draft',   -- draft / confirmed
  confirmed_by uuid references manual_staff(id) on delete set null,
  confirmed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (ym, branch_id, staff_id)
);

alter table ops_pay_profiles enable row level security;
alter table ops_settings enable row level security;
alter table ops_pay_runs enable row level security;
drop policy if exists "anon full access" on ops_pay_profiles;
create policy "anon full access" on ops_pay_profiles for all using (true) with check (true);
drop policy if exists "anon full access" on ops_settings;
create policy "anon full access" on ops_settings for all using (true) with check (true);
drop policy if exists "anon full access" on ops_pay_runs;
create policy "anon full access" on ops_pay_runs for all using (true) with check (true);
