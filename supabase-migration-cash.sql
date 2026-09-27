-- =========================================================
-- 본노엘 운영 앱: 자금 흐름 (법인 통장 거래내역 → 자동 분류 → 월 자금 흐름표)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- 먼저 필요한 것: supabase-migration-prepay.sql (사장님 코드를 같이 씀)
--
-- 잠금 방식 (법인 서류와 같음):
--   · cash_ 표는 앱에서 직접 읽기·쓰기 불가 (RLS 켜고 허용 규칙 없음)
--   · 모든 일은 아래 함수로만, 함수가 "사장님 코드(선결제와 같은 6자리)"를 서버에서 확인
--   · 분류(배민·카드 대금·4대보험 …)는 앱이 규칙으로 그때그때 계산 → 규칙을 고치면 지난 거래도 바로 바뀜
--     표에는 사장님이 "직접 고른 항목"만 저장
-- =========================================================

-- 1. 통장
create table if not exists cash_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,                 -- 예: 성수 신한
  bank text not null,                 -- 신한 / 국민 / 기업 …
  last4 text,                         -- 계좌번호 끝 4자리 (엑셀에 계좌번호가 있으면 자동으로 찾음)
  branch_id text,                     -- manual_branches.id (null = 공통)
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

-- 2. 거래 (은행 엑셀 한 줄 = 한 행)
create table if not exists cash_tx (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references cash_accounts(id) on delete cascade,
  tx_at timestamp not null,           -- 은행 거래일시 (한국 시간 그대로)
  amount_in bigint not null default 0,
  amount_out bigint not null default 0,
  balance bigint,
  memo text,                          -- 적요 (FB자금, BZ급여, 보험료 …)
  party text,                         -- 내용 / 보낸분·받는분
  place text,                         -- 거래점
  category text,                      -- 사장님이 직접 고른 항목 (null = 규칙으로 자동)
  note text,
  dup_key text not null,              -- 같은 파일을 두 번 올려도 한 번만 저장
  created_at timestamptz not null default now(),
  unique (account_id, dup_key)
);
create index if not exists cash_tx_at_idx on cash_tx (tx_at);

-- 3. 사장님이 가르친 분류 규칙 ("이 이름은 앞으로 월세")
create table if not exists cash_rules (
  id uuid primary key default gen_random_uuid(),
  field text not null default 'party' check (field in ('party', 'memo')),
  pattern text not null,
  dir text not null default 'any' check (dir in ('in', 'out', 'any')),
  category text not null,
  created_at timestamptz not null default now(),
  unique (field, pattern, dir)
);

alter table cash_accounts enable row level security;
alter table cash_tx enable row level security;
alter table cash_rules enable row level security;

-- ===== 내부 도우미 =====
create or replace function cash__ok(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  return coalesce(prepay__auth(null, p_code), '') = 'owner';
end $$;

create or replace function cash__err() returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', false, 'error', '사장님 코드가 틀려요 (선결제 사장님 코드와 같은 6자리)')
$$;

-- ===== 사장님 코드가 맞아야 하는 것 =====
create or replace function cash_login(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 기간 거래 + 통장·규칙·월 목록·통장별 마지막 잔액을 한 번에
-- p_from/p_to 가 비면: 마지막 거래가 있는 달까지 6개월
create or replace function cash_get(p_code text, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_to date; v_from date;
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  v_to := coalesce(p_to, (date_trunc('month', (select max(tx_at) from cash_tx)) + interval '1 month - 1 day')::date, current_date);
  v_from := coalesce(p_from, (date_trunc('month', v_to) - interval '5 months')::date);
  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'accounts', coalesce((select jsonb_agg(to_jsonb(a) order by a.sort_order, a.name) from cash_accounts a), '[]'::jsonb),
    'rules', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at) from cash_rules r), '[]'::jsonb),
    'months', coalesce((select jsonb_agg(m order by m) from (select distinct to_char(tx_at, 'YYYY-MM') m from cash_tx) x), '[]'::jsonb),
    'last', coalesce((select jsonb_agg(jsonb_build_object('account_id', l.account_id, 'tx_at', to_char(l.tx_at, 'YYYY-MM-DD HH24:MI:SS'), 'balance', l.balance, 'n', l.n)) from (
       select distinct on (t.account_id) t.account_id, t.tx_at, t.balance, count(*) over (partition by t.account_id) n
       from cash_tx t order by t.account_id, t.tx_at desc, t.created_at desc) l), '[]'::jsonb),
    -- 거래는 짧은 배열로 (용량 줄이기): [id, 통장, 일시, 입금, 출금, 잔액, 적요, 내용, 거래점, 직접고른항목, 메모]
    'tx', coalesce((select jsonb_agg(jsonb_build_array(t.id, t.account_id, to_char(t.tx_at, 'YYYY-MM-DD HH24:MI:SS'), t.amount_in, t.amount_out, t.balance, t.memo, t.party, t.place, t.category, t.note) order by t.tx_at, t.id)
       from cash_tx t where t.tx_at >= v_from and t.tx_at < v_to + 1), '[]'::jsonb));
end $$;

create or replace function cash_save_account(p_code text, p_acc jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  if coalesce(trim(p_acc->>'name'), '') = '' or coalesce(trim(p_acc->>'bank'), '') = '' then
    return jsonb_build_object('ok', false, 'error', '통장 이름과 은행을 넣어 주세요');
  end if;
  if nullif(p_acc->>'id', '') is not null then
    update cash_accounts set name = trim(p_acc->>'name'), bank = trim(p_acc->>'bank'), last4 = nullif(trim(p_acc->>'last4'), ''),
      branch_id = nullif(p_acc->>'branch_id', ''), sort_order = coalesce((p_acc->>'sort_order')::int, sort_order)
    where id = (p_acc->>'id')::uuid returning id into v_id;
  else
    insert into cash_accounts (name, bank, last4, branch_id, sort_order)
    values (trim(p_acc->>'name'), trim(p_acc->>'bank'), nullif(trim(p_acc->>'last4'), ''), nullif(p_acc->>'branch_id', ''), coalesce((p_acc->>'sort_order')::int, 0))
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 통장 지우기 = 그 통장 거래도 같이 지워짐
create or replace function cash_delete_account(p_code text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  delete from cash_accounts where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 거래 올리기: p_rows = [{tx_at, amount_in, amount_out, balance, memo, party, place, dup_key}, …]
create or replace function cash_import(p_code text, p_account uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int; v_total int;
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  if not exists (select 1 from cash_accounts where id = p_account) then
    return jsonb_build_object('ok', false, 'error', '통장을 먼저 골라 주세요');
  end if;
  v_total := jsonb_array_length(p_rows);
  insert into cash_tx (account_id, tx_at, amount_in, amount_out, balance, memo, party, place, dup_key)
  select p_account, r.tx_at, coalesce(r.amount_in, 0), coalesce(r.amount_out, 0), r.balance, r.memo, r.party, r.place, r.dup_key
  from jsonb_to_recordset(p_rows) as r(tx_at timestamp, amount_in bigint, amount_out bigint, balance bigint, memo text, party text, place text, dup_key text)
  where r.tx_at is not null and r.dup_key is not null
  on conflict (account_id, dup_key) do nothing;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'inserted', v_n, 'skipped', v_total - v_n);
end $$;

-- 한 통장의 거래를 기간으로 지우기 (잘못 올렸을 때). 기간이 비면 그 통장 전부
create or replace function cash_delete_range(p_code text, p_account uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  delete from cash_tx where account_id = p_account
    and (p_from is null or tx_at >= p_from) and (p_to is null or tx_at < p_to + 1);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'deleted', v_n);
end $$;

-- 거래 몇 개의 항목을 직접 정하기 (null = 다시 자동)
create or replace function cash_set_category(p_code text, p_ids uuid[], p_category text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  update cash_tx set category = nullif(p_category, '') where id = any(p_ids);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'updated', v_n);
end $$;

create or replace function cash_set_note(p_code text, p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  update cash_tx set note = nullif(trim(p_note), '') where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 규칙 저장 (같은 글자·같은 방향이면 항목만 바꿈)
create or replace function cash_save_rule(p_code text, p_rule jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  if coalesce(trim(p_rule->>'pattern'), '') = '' or coalesce(p_rule->>'category', '') = '' then
    return jsonb_build_object('ok', false, 'error', '글자와 항목을 넣어 주세요');
  end if;
  insert into cash_rules (field, pattern, dir, category)
  values (coalesce(p_rule->>'field', 'party'), trim(p_rule->>'pattern'), coalesce(p_rule->>'dir', 'any'), p_rule->>'category')
  on conflict (field, pattern, dir) do update set category = excluded.category
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function cash_delete_rule(p_code text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not cash__ok(p_code) then return cash__err(); end if;
  delete from cash_rules where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function cash__ok(text) from public, anon, authenticated;

select '자금 흐름 준비 완료 — 앱 홈의 "자금" 폴더에서 사장님 코드로 들어가세요' as 결과;
