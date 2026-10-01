-- =========================================================
-- 비상용: 보안-2-잠금.sql 을 되돌려서 예전처럼(누구나 열림) 만들기
-- 아침에 매장에서 앱이 안 될 때만 쓰세요. 앱도 예전 버전으로 되돌려야 해요(Claude에게 "보안 되돌려줘").
-- 사용법: Supabase → SQL Editor → 전체 붙여넣기 → Run (여러 번 실행해도 안전)
-- =========================================================

-- 1. 직원 비밀번호 칸 되살리기 (잠그기 전 숫자로. 그 뒤에 새로 정한 비밀번호는 1225로)
drop trigger if exists staff_row_guard on manual_staff;
alter table manual_staff add column if not exists pin text;
update manual_staff m set pin = b.pin from staff_pin_backup_20261001 b where b.staff_id = m.id and m.pin is null;
update manual_staff m set pin = '1225' where m.pin is null and exists (select 1 from staff_secrets s where s.staff_id = m.id and s.pin_hash is not null);

-- 2. 표 정책을 예전처럼 "누구나"로
create or replace function pg_temp.open_table(t text) returns void language plpgsql as $$
declare p record;
begin
  if to_regclass('public.' || t) is null then return; end if;
  for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
    execute format('drop policy %I on public.%I', p.policyname, t);
  end loop;
  execute format('create policy "anon full access" on public.%I for all using (true) with check (true)', t);
end $$;
select pg_temp.open_table(t) from unnest(array['applicants', 'baker_candidates', 'baker_branches', 'ops_pay_runs', 'ops_pay_profiles', 'ops_settings',
  'ops_expenses', 'ops_cards', 'ops_merchant_rules', 'ops_subsidy_employees', 'ops_subsidy_cases', 'ops_subsidy_logs']) t;

-- 3. 사진함 정책도 예전처럼
drop policy if exists bn_documents_select on storage.objects;
drop policy if exists bn_documents_insert on storage.objects;
drop policy if exists bn_documents_delete on storage.objects;
drop policy if exists bn_receipts_select on storage.objects;
drop policy if exists bn_receipts_insert on storage.objects;
drop policy if exists bn_receipts_delete on storage.objects;
drop policy if exists "documents read" on storage.objects;
drop policy if exists "documents insert" on storage.objects;
drop policy if exists "documents delete" on storage.objects;
drop policy if exists "receipts read" on storage.objects;
drop policy if exists "receipts insert" on storage.objects;
drop policy if exists "receipts delete" on storage.objects;
drop policy if exists "anyone can view resume photo" on storage.objects;
create policy "documents read" on storage.objects for select using (bucket_id = 'documents');
create policy "documents insert" on storage.objects for insert with check (bucket_id = 'documents');
create policy "documents delete" on storage.objects for delete using (bucket_id = 'documents');
create policy "receipts read" on storage.objects for select using (bucket_id = 'receipts');
create policy "receipts insert" on storage.objects for insert with check (bucket_id = 'receipts');
create policy "receipts delete" on storage.objects for delete using (bucket_id = 'receipts');
create policy "anyone can view resume photo" on storage.objects for select to anon, authenticated using (bucket_id = 'resume-photos');

select (select count(*) from manual_staff where pin is not null) as 비밀번호_되살린_사람;
