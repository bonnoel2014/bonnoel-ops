-- =========================================================
-- 본노엘 보안 2단계: 공개 키로 열려 있던 중요한 표·사진함 잠그기
-- 사용법: Supabase → SQL Editor → New query → 이 파일 전체 붙여넣기 → Run
--         (글자를 선택한 채로 Run 하면 선택한 부분만 실행되니, 아무것도 선택하지 않고 Run)
--         여러 번 실행해도 안전해요.
-- 먼저 필요한 것: 보안-1-출입증-준비.sql 실행 + 새 앱(운영·채용) 배포 + 메일·영수증 함수 3개 다시 올리기
--
-- 잠그는 것                         누가 볼 수 있나
--   직원 비밀번호(manual_staff.pin)  → 칸을 없앰 (암호로 바꾼 것만 staff_secrets 에)
--   직원 역할(사장·매니저·매장폰)    → 사장님만 바꿀 수 있음
--   알바 지원자(applicants)          → 매니저·매장폰·사장님 (지원서 보내기는 누구나)
--   베이커 지원자(baker_candidates)  → 사장님 (지원서 보내기는 누구나)
--   급여(ops_pay_runs)               → 사장님
--   급여 설정(ops_pay_profiles)      → 매니저·매장폰·사장님
--   설정(ops_settings)               → 항목별 (서류 양식은 로그인한 직원, 급여 요율은 매니저 이상, 나머지는 사장님)
--   카드 지출(ops_expenses)          → 매니저 이상 + 본인이 올린 것
--   카드 목록·가게 분류 규칙         → 로그인한 직원
--   지원금(ops_subsidy_*)            → 사장님
--   서류 사진함(documents)           → 사장님 전부 / 매니저는 보건증·증명서·유니폼 / 직원은 본인 것
--   영수증 사진함(receipts)          → 로그인한 직원
--   지원서 사진(resume-photos)       → 목록 보기 막음 (지원서에서 올리기는 그대로)
-- "로그인" = 운영 앱·채용 관리에서 이름+비밀번호로 받은 출입증, 또는 사장님 앱 이메일 로그인
-- =========================================================

-- 0. 1단계를 먼저 했는지 확인
do $$
begin
  if to_regprocedure('public.staff__is_manager()') is null then
    raise exception '보안-1-출입증-준비.sql 을 먼저 실행해 주세요';
  end if;
end $$;

-- 1. 직원 비밀번호 칸 없애기 (지우기 전에 암호로 한 번 더 옮겨 담고, 원래 숫자는 잠긴 표에 1주일 보관)
create table if not exists staff_pin_backup_20261001 (staff_id uuid primary key, pin text, saved_at timestamptz not null default now());
alter table staff_pin_backup_20261001 enable row level security;
revoke all on staff_pin_backup_20261001 from anon, authenticated;
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'manual_staff' and column_name = 'pin') then
    execute $q$ insert into staff_pin_backup_20261001 (staff_id, pin) select id, pin from manual_staff where pin is not null on conflict (staff_id) do nothing $q$;
    execute $q$
      insert into staff_secrets (staff_id, pin_hash)
      select id, extensions.crypt(pin, extensions.gen_salt('bf', 8)) from manual_staff where pin ~ '^\d{4}$'
      on conflict (staff_id) do nothing
    $q$;
    alter table manual_staff drop column pin;
  end if;
end $$;

-- 2. 직원 명단 지키기: 사장·매니저·매장폰 줄과 역할은 사장님(또는 매니저)만 손댈 수 있음
--    (근무자 줄 추가·매장 옮기기는 매뉴얼북 관리 화면에서도 하니까 그대로 둠 → 3단계에서 잠금)
create or replace function staff__guard_staff_row() returns trigger
language plpgsql set search_path = public as $$
begin
  -- 앱(공개 키·로그인 계정)에서 온 요청만 검사. SQL Editor·서버 함수(서버 전용 키)는 통과
  if current_user not in ('anon', 'authenticated') then return coalesce(new, old); end if;
  if tg_op = 'INSERT' then
    if coalesce(new.role, 'staff') <> 'staff' and not staff__is_owner() then
      raise exception '사장님만 매니저·사장·매장폰 계정을 만들 수 있어요';
    end if;
    return new;
  end if;
  if tg_op = 'UPDATE' then
    if new.role is distinct from old.role and not staff__is_owner() then
      raise exception '사장님만 역할을 바꿀 수 있어요';
    end if;
    if coalesce(old.role, 'staff') <> 'staff' and not staff__is_manager() then
      raise exception '매니저·사장님 계정은 로그인해야 고칠 수 있어요';
    end if;
    return new;
  end if;
  -- DELETE
  if coalesce(old.role, 'staff') <> 'staff' and not staff__is_owner() then
    raise exception '사장님만 지울 수 있어요';
  end if;
  return old;
end $$;
revoke all on function staff__guard_staff_row() from public, anon, authenticated;
drop trigger if exists staff_row_guard on manual_staff;
create trigger staff_row_guard before insert or update or delete on manual_staff for each row execute function staff__guard_staff_row();

-- 3. 표 잠금 도우미: 그 표의 예전 정책(누구나 다 됨)을 모두 지우고 RLS 켜기
create or replace function pg_temp.reset_policies(t text) returns void language plpgsql as $$
declare p record;
begin
  execute format('alter table public.%I enable row level security', t);
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
    execute format('drop policy %I on public.%I', p.policyname, t);
  end loop;
  execute format('grant select, insert, update, delete on public.%I to anon, authenticated', t);
end $$;

-- 4. 알바 지원자: 지원서 보내기는 누구나, 보기·고치기·지우기는 매니저 이상
select pg_temp.reset_policies('applicants');
create policy apply_insert on applicants for insert to anon, authenticated with check (true);
create policy mgr_select on applicants for select to anon, authenticated using ((select staff__is_manager()));
create policy mgr_update on applicants for update to anon, authenticated using ((select staff__is_manager())) with check ((select staff__is_manager()));
create policy mgr_delete on applicants for delete to anon, authenticated using ((select staff__is_manager()));

-- 5. 베이커 지원자: 지원서 보내기는 누구나, 나머지는 사장님
select pg_temp.reset_policies('baker_candidates');
create policy apply_insert on baker_candidates for insert to anon, authenticated with check (true);
create policy owner_select on baker_candidates for select to anon, authenticated using ((select staff__is_owner()));
create policy owner_update on baker_candidates for update to anon, authenticated using ((select staff__is_owner())) with check ((select staff__is_owner()));
create policy owner_delete on baker_candidates for delete to anon, authenticated using ((select staff__is_owner()));

-- 베이커 지원서의 지점 목록: 보기는 누구나(지원서 화면), 고치기는 매니저 이상
select pg_temp.reset_policies('baker_branches');
create policy anyone_select on baker_branches for select to anon, authenticated using (true);
create policy mgr_write on baker_branches for all to anon, authenticated using ((select staff__is_manager())) with check ((select staff__is_manager()));

-- 6. 급여
select pg_temp.reset_policies('ops_pay_runs');
create policy owner_all on ops_pay_runs for all to anon, authenticated using ((select staff__is_owner())) with check ((select staff__is_owner()));
select pg_temp.reset_policies('ops_pay_profiles');
create policy mgr_all on ops_pay_profiles for all to anon, authenticated using ((select staff__is_manager())) with check ((select staff__is_manager()));

-- 7. 설정: 항목(key)마다 다르게
--    docs(서류 양식·직인)  보기: 로그인한 직원(매장폰 서명 화면) / 고치기: 사장님
--    pay, staff_flags      보기: 매니저 이상 / 고치기: 사장님
--    stmt:*(카드 명세서)    보기·고치기: 매니저 이상
--    그 밖(vendor_stmt 등) 사장님
create or replace function staff__settings_read(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_key = 'docs' then staff__is_staff()
    when p_key in ('pay', 'staff_flags') or p_key like 'stmt:%' then staff__is_manager()
    else staff__is_owner() end;
$$;
create or replace function staff__settings_write(p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_key like 'stmt:%' then staff__is_manager() else staff__is_owner() end;
$$;
grant execute on function staff__settings_read(text), staff__settings_write(text) to anon, authenticated;
select pg_temp.reset_policies('ops_settings');
create policy by_key_select on ops_settings for select to anon, authenticated using (staff__settings_read(key));
create policy by_key_insert on ops_settings for insert to anon, authenticated with check (staff__settings_write(key));
create policy by_key_update on ops_settings for update to anon, authenticated using (staff__settings_write(key)) with check (staff__settings_write(key));
create policy by_key_delete on ops_settings for delete to anon, authenticated using (staff__settings_write(key));

-- 8. 카드 지출
select pg_temp.reset_policies('ops_expenses');
create policy staff_select on ops_expenses for select to anon, authenticated using ((select staff__is_manager()) or uploaded_by = (select staff__id()));
create policy staff_insert on ops_expenses for insert to anon, authenticated with check ((select staff__is_staff()));
create policy mgr_update on ops_expenses for update to anon, authenticated using ((select staff__is_manager())) with check ((select staff__is_manager()));
create policy mgr_delete on ops_expenses for delete to anon, authenticated using ((select staff__is_manager()));
select pg_temp.reset_policies('ops_cards');
create policy staff_select on ops_cards for select to anon, authenticated using ((select staff__is_staff()));
create policy owner_write on ops_cards for insert to anon, authenticated with check ((select staff__is_owner()));
create policy owner_update on ops_cards for update to anon, authenticated using ((select staff__is_owner())) with check ((select staff__is_owner()));
create policy owner_delete on ops_cards for delete to anon, authenticated using ((select staff__is_owner()));
select pg_temp.reset_policies('ops_merchant_rules');
create policy staff_all on ops_merchant_rules for all to anon, authenticated using ((select staff__is_staff())) with check ((select staff__is_staff()));

-- 9. 지원금
select pg_temp.reset_policies('ops_subsidy_employees');
create policy owner_all on ops_subsidy_employees for all to anon, authenticated using ((select staff__is_owner())) with check ((select staff__is_owner()));
select pg_temp.reset_policies('ops_subsidy_cases');
create policy owner_all on ops_subsidy_cases for all to anon, authenticated using ((select staff__is_owner())) with check ((select staff__is_owner()));
select pg_temp.reset_policies('ops_subsidy_logs');
create policy owner_all on ops_subsidy_logs for all to anon, authenticated using ((select staff__is_owner())) with check ((select staff__is_owner()));

-- 10. 사진함(storage)
--  documents 경로: <직원id>/<묶음id>/파일 (계약서·서명·등본·통장사본), health/<직원id>/…, subsidy/…, cert/…
create or replace function staff__doc_read(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select staff__is_owner()
    or (staff__is_manager() and (p_name like 'health/%' or p_name like 'cert/%' or p_name ~ '/uniform_(return|swap)_[^/]*$'))
    or (staff__id() is not null and (p_name like staff__id()::text || '/%' or p_name like 'health/' || staff__id()::text || '/%'));
$$;
create or replace function staff__doc_write(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select staff__is_manager()
    or (staff__id() is not null and (p_name like staff__id()::text || '/%' or p_name like 'health/' || staff__id()::text || '/%'));
$$;
create or replace function staff__doc_delete(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select staff__is_owner() or (staff__is_manager() and p_name like 'health/%');
$$;
grant execute on function staff__doc_read(text), staff__doc_write(text), staff__doc_delete(text) to anon, authenticated;

drop policy if exists "documents read" on storage.objects;
drop policy if exists "documents insert" on storage.objects;
drop policy if exists "documents delete" on storage.objects;
drop policy if exists "receipts read" on storage.objects;
drop policy if exists "receipts insert" on storage.objects;
drop policy if exists "receipts delete" on storage.objects;
drop policy if exists "anyone can view resume photo" on storage.objects;
drop policy if exists bn_documents_select on storage.objects;
drop policy if exists bn_documents_insert on storage.objects;
drop policy if exists bn_documents_delete on storage.objects;
drop policy if exists bn_receipts_select on storage.objects;
drop policy if exists bn_receipts_insert on storage.objects;
drop policy if exists bn_receipts_delete on storage.objects;
create policy bn_documents_select on storage.objects for select to anon, authenticated using (bucket_id = 'documents' and staff__doc_read(name));
create policy bn_documents_insert on storage.objects for insert to anon, authenticated with check (bucket_id = 'documents' and staff__doc_write(name));
create policy bn_documents_delete on storage.objects for delete to anon, authenticated using (bucket_id = 'documents' and staff__doc_delete(name));
create policy bn_receipts_select on storage.objects for select to anon, authenticated using (bucket_id = 'receipts' and (select staff__is_staff()));
create policy bn_receipts_insert on storage.objects for insert to anon, authenticated with check (bucket_id = 'receipts' and (select staff__is_staff()));
create policy bn_receipts_delete on storage.objects for delete to anon, authenticated using (bucket_id = 'receipts' and (select staff__is_manager()));
-- resume-photos: 지원서에서 올리기("anyone can upload resume photo")는 그대로. 사진은 공개 주소로만 보임(목록은 못 봄)

-- 11. 확인
select
  (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'manual_staff' and column_name = 'pin') as "pin칸_남음(0이어야)",
  (select count(*) from staff_secrets where pin_hash is not null) as 비밀번호_있는_사람,
  (select count(*) from pg_policies where schemaname = 'public' and tablename in ('applicants', 'baker_candidates', 'ops_pay_runs', 'ops_pay_profiles', 'ops_settings', 'ops_expenses', 'ops_cards', 'ops_merchant_rules', 'ops_subsidy_employees', 'ops_subsidy_cases', 'ops_subsidy_logs') and qual = 'true' and cmd <> 'INSERT') as "누구나_열린_정책(0이어야)";
