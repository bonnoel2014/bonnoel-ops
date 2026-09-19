-- =========================================================
-- 본노엘 운영 앱 10차: 청년지원금 관리 (청년일자리도약장려금)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================

-- 1. 참여 직원 (청년일자리도약장려금 대상자)
create table if not exists ops_subsidy_employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  agency text not null default 'makein26',                            -- jobmoa25(25년 잡모아) / makein26(26년 메이크인)
  hire_on date not null,
  branch_id uuid references manual_branches(id) on delete set null,
  active boolean not null default true,
  stop_reason text,                                                   -- 퇴사 등으로 중단된 이유
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2. 단계별 신청 건 (직원 한 명당 5단계: 참여자등록/6·9·12개월/2년차 자동 생성)
create table if not exists ops_subsidy_cases (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references ops_subsidy_employees(id) on delete cascade,
  stage text not null,                                                -- register / m6 / m9 / m12 / y2
  due_on date,
  status text not null default 'waiting',                             -- waiting / submitted / revision / accepted / paid / stopped
  checklist jsonb not null default '[]',                              -- [{name, done, file_path}]
  amount numeric,
  paid_on date,
  stopped_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (employee_id, stage)
);
create index if not exists ops_subsidy_cases_employee_idx on ops_subsidy_cases(employee_id);

-- 3. 진행 기록 타임라인 (제출·기관 회신·수정요청·입금 등을 메모+파일로 계속 쌓음)
create table if not exists ops_subsidy_logs (
  id uuid primary key default gen_random_uuid(),
  case_id uuid not null references ops_subsidy_cases(id) on delete cascade,
  content text,
  file_path text,
  created_by uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ops_subsidy_logs_case_idx on ops_subsidy_logs(case_id);

alter table ops_subsidy_employees enable row level security;
drop policy if exists "anon full access" on ops_subsidy_employees;
create policy "anon full access" on ops_subsidy_employees for all using (true) with check (true);

alter table ops_subsidy_cases enable row level security;
drop policy if exists "anon full access" on ops_subsidy_cases;
create policy "anon full access" on ops_subsidy_cases for all using (true) with check (true);

alter table ops_subsidy_logs enable row level security;
drop policy if exists "anon full access" on ops_subsidy_logs;
create policy "anon full access" on ops_subsidy_logs for all using (true) with check (true);

-- 4. 서류 파일 저장소: 입사 서류(6차)에서 만든 documents 버킷을 subsidy/ 폴더로 구분해서 같이 씀.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 15728640, array['application/pdf', 'image/png', 'image/jpeg'])
on conflict (id) do update set allowed_mime_types = array['application/pdf', 'image/png', 'image/jpeg'];

drop policy if exists "documents read" on storage.objects;
create policy "documents read" on storage.objects for select using (bucket_id = 'documents');
drop policy if exists "documents insert" on storage.objects;
create policy "documents insert" on storage.objects for insert with check (bucket_id = 'documents');
drop policy if exists "documents delete" on storage.objects;
create policy "documents delete" on storage.objects for delete using (bucket_id = 'documents');

-- 확인: 들어간 줄 보기
select e.name, c.stage, c.due_on, c.status, c.amount from ops_subsidy_cases c join ops_subsidy_employees e on e.id = c.employee_id order by e.name, c.due_on;
