-- =========================================================
-- 본노엘 운영 앱: 사장님 지시 + 설비 대장 + 고장 신고 (경영 도구 v1 — bonnoel-owner/docs/경영도구/PRD_전체.md)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- 매장폰(운영 앱)에서 보고 누르는 것이라 다른 운영 표와 같은 수준(anon 읽기/쓰기). 수리 비용은 사장님 표(owner_repair_costs)에만.
-- 사진은 영수증과 같은 저장소(receipts)에 tasks/·repairs/ 폴더로.
-- =========================================================

-- 1. 사장님 지시 (매장으로 보냄, 그날 근무자 누구든 완료)
create table if not exists ops_tasks (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  body text not null,                          -- 무엇을
  due_on date,                                 -- 언제까지 (비우면 기한 없음)
  need_photo boolean not null default false,   -- 완료할 때 사진 꼭
  status text not null default 'open' check (status in ('open', 'done', 'ok')),   -- open 할 일 / done 완료(사장님 확인 기다림) / ok 사장님 확인
  done_by uuid references manual_staff(id) on delete set null,
  done_at timestamptz,
  done_photo text,                             -- receipts 저장소 경로
  done_memo text,
  redo_memo text,                              -- 사장님 "다시 해 주세요" 이유 (다시 open 으로)
  checked_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists ops_tasks_branch_idx on ops_tasks (branch_id, status, created_at desc);

-- 2. 설비 대장
create table if not exists ops_equipment (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  name text not null,                          -- 예: 쇼케이스 2번, 데크 오븐
  model text,
  bought_on date,
  warranty_until date,                         -- 무상 보증 끝나는 날
  as_name text,                                -- A/S 업체
  as_phone text,
  memo text,
  active boolean not null default true,
  sort int not null default 100,
  created_at timestamptz not null default now()
);
create index if not exists ops_equipment_branch_idx on ops_equipment (branch_id, active);

-- 3. 고장 신고 (매장폰) → 사장님 수리 처리
create table if not exists ops_repairs (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  equipment_id uuid references ops_equipment(id) on delete set null,
  equipment_text text,                         -- 목록에 없는 설비면 글로
  symptom text not null,
  photo_path text,                             -- receipts 저장소 경로
  urgent boolean not null default false,       -- 영업에 지장 있음
  reported_by uuid references manual_staff(id) on delete set null,
  status text not null default 'open' check (status in ('open', 'fixing', 'fixed')),
  fixed_on date,
  fix_memo text,
  created_at timestamptz not null default now()
);
create index if not exists ops_repairs_branch_idx on ops_repairs (branch_id, status, created_at desc);

alter table ops_tasks enable row level security;
alter table ops_equipment enable row level security;
alter table ops_repairs enable row level security;
drop policy if exists "anon full access" on ops_tasks;
create policy "anon full access" on ops_tasks for all using (true) with check (true);
drop policy if exists "anon full access" on ops_equipment;
create policy "anon full access" on ops_equipment for all using (true) with check (true);
drop policy if exists "anon full access" on ops_repairs;
create policy "anon full access" on ops_repairs for all using (true) with check (true);
grant select, insert, update, delete on ops_tasks, ops_equipment, ops_repairs to anon, authenticated;

-- 4. 수리 비용 — 사장님만 (owner.sql 의 owner__is() 가 있으면 만들어요)
do $$ begin
  if exists (select 1 from pg_proc where proname = 'owner__is') then
    execute 'create table if not exists owner_repair_costs (repair_id uuid primary key references ops_repairs(id) on delete cascade, cost bigint not null default 0, vendor text, updated_at timestamptz not null default now())';
    execute 'alter table owner_repair_costs enable row level security';
    execute 'revoke all on owner_repair_costs from anon';
    execute 'grant select, insert, update, delete on owner_repair_costs to authenticated';
    execute 'drop policy if exists owner_all on owner_repair_costs';
    execute 'create policy owner_all on owner_repair_costs for all to authenticated using (owner__is()) with check (owner__is())';
  end if;
end $$;

select '지시·설비·고장 준비 완료' as 결과;
