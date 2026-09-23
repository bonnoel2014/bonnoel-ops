-- ===== 선결제 (손님이 미리 충전해 두고 4매장에서 쓰는 잔액 장부) =====
-- Supabase → SQL Editor 에 통째로 붙여넣고 Run. 여러 번 실행해도 안전해요.
--
-- 돈 장부라서 운영 앱의 다른 표와 다르게 잠가 둡니다:
--   · prepay_ 표는 앱에서 직접 읽기·쓰기 불가 (RLS 켜고 허용 규칙 없음)
--   · 충전·사용·취소·환불은 아래 함수로만, 함수가 매장 코드/사장님 코드를 서버에서 확인
--   · 코드는 암호화(bcrypt)해서 저장 — 사장님도 원래 숫자는 못 봄 (잊으면 사장님 코드로 새로 정하기)

create extension if not exists pgcrypto with schema extensions;

-- 설정 (한 줄뿐)
create table if not exists prepay_settings (
  id int primary key default 1 check (id = 1),
  bonus_min int not null default 100000,        -- 이 금액 이상 한 번에 충전하면
  bonus_rate numeric not null default 5,        -- 이 % 만큼 추가 적립
  owner_code_hash text,                         -- 사장님 코드 (처음엔 비어 있음 → 앱에서 사장님이 정함)
  fail_count int not null default 0,            -- 코드 틀린 횟수 (20번이면 5분 잠금)
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
insert into prepay_settings (id) values (1) on conflict (id) do nothing;

-- 매장별 코드
create table if not exists prepay_branch_codes (
  branch_id uuid primary key references manual_branches(id) on delete cascade,
  code_hash text not null,
  updated_at timestamptz not null default now()
);

-- 손님 (휴대폰 번호 1개 = 1명)
create table if not exists prepay_customers (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,                   -- 숫자만 (01012345678)
  name text,
  pin_hash text,                                -- 손님이 잔액 조회할 때 쓰는 4자리 (선택)
  fail_count int not null default 0,
  locked_until timestamptz,
  memo text,
  created_branch uuid references manual_branches(id) on delete set null,
  created_at timestamptz not null default now()
);

-- 장부 (지우지 않음. 잘못하면 '취소' 줄을 새로 남김)
create table if not exists prepay_ledger (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references prepay_customers(id) on delete restrict,
  kind text not null check (kind in ('charge', 'use', 'refund', 'import', 'cancel')),
  amount int not null,                          -- 잔액 변화 (충전·옮기기 +, 사용·환불 −, 취소는 원래 줄의 반대)
  paid int not null default 0,                  -- 실제로 오간 돈 (충전 +, 환불 −)
  bonus int not null default 0,                 -- 추가 적립 (충전 +, 환불·취소 −)
  branch_id uuid references manual_branches(id) on delete set null,
  staff_id uuid references manual_staff(id) on delete set null,
  staff_name text,
  by_owner boolean not null default false,      -- 사장님 코드로 한 일
  cancel_of uuid references prepay_ledger(id),  -- 취소 줄이면 원래 줄
  memo text,
  created_at timestamptz not null default now()
);
create unique index if not exists prepay_ledger_cancel_once on prepay_ledger(cancel_of) where cancel_of is not null;
create index if not exists prepay_ledger_customer on prepay_ledger(customer_id, created_at);
create index if not exists prepay_ledger_created on prepay_ledger(created_at);

-- 잠금: 앱(anon)에서 직접 못 건드림
alter table prepay_settings enable row level security;
alter table prepay_branch_codes enable row level security;
alter table prepay_customers enable row level security;
alter table prepay_ledger enable row level security;
revoke all on prepay_settings, prepay_branch_codes, prepay_customers, prepay_ledger from anon, authenticated;

-- ===== 내부 도우미 =====
create or replace function prepay__digits(p text) returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g')
$$;

create or replace function prepay__balance(p_customer uuid) returns int language sql stable
set search_path = public as $$
  select coalesce(sum(amount), 0)::int from prepay_ledger where customer_id = p_customer
$$;

-- 코드 확인: 'owner' / 'branch' / 'locked' / null(틀림)
create or replace function prepay__auth(p_branch uuid, p_code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare s prepay_settings; h text;
begin
  select * into s from prepay_settings where id = 1 for update;
  if s.locked_until is not null and s.locked_until > now() then return 'locked'; end if;
  if coalesce(p_code, '') !~ '^[0-9]{6}$' then return null; end if;
  if s.owner_code_hash is not null and s.owner_code_hash = crypt(p_code, s.owner_code_hash) then
    update prepay_settings set fail_count = 0 where id = 1; return 'owner';
  end if;
  select code_hash into h from prepay_branch_codes where branch_id = p_branch;
  if h is not null and h = crypt(p_code, h) then
    update prepay_settings set fail_count = 0 where id = 1; return 'branch';
  end if;
  update prepay_settings set fail_count = fail_count + 1,
    locked_until = case when fail_count + 1 >= 20 then now() + interval '5 minutes' else null end
  where id = 1;
  return null;
end $$;

create or replace function prepay__err(p_role text) returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', false, 'error',
    case when p_role = 'locked' then '코드를 여러 번 틀려서 5분 동안 잠겼어요'
         else '선결제 코드가 틀려요' end)
$$;

create or replace function prepay__staff_name(p_staff uuid) returns text language sql stable
set search_path = public as $$ select name from manual_staff where id = p_staff $$;

create or replace function prepay__today_kst() returns date language sql stable as $$
  select (now() at time zone 'Asia/Seoul')::date
$$;

-- ===== 누구나 (비밀 없음) =====
create or replace function prepay_status() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'ready', (select owner_code_hash is not null from prepay_settings where id = 1),
    'bonus_min', (select bonus_min from prepay_settings where id = 1),
    'bonus_rate', (select bonus_rate from prepay_settings where id = 1),
    'branches', coalesce((select jsonb_agg(branch_id) from prepay_branch_codes), '[]'::jsonb))
$$;

-- 사장님 코드 처음 정하기 (비어 있을 때만)
create or replace function prepay_owner_init(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if coalesce(p_code, '') !~ '^[0-9]{6}$' then return jsonb_build_object('ok', false, 'error', '숫자 6자리로 정해 주세요'); end if;
  update prepay_settings set owner_code_hash = crypt(p_code, gen_salt('bf')), updated_at = now()
  where id = 1 and owner_code_hash is null;
  if not found then return jsonb_build_object('ok', false, 'error', '사장님 코드가 이미 정해져 있어요'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ===== 코드가 맞아야 하는 것 =====
create or replace function prepay_login(p_branch uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(p_branch, p_code);
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  return jsonb_build_object('ok', true, 'role', r);
end $$;

-- 손님 찾기: 숫자면 번호 뒷자리/전체, 아니면 이름
create or replace function prepay_find(p_branch uuid, p_code text, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(p_branch, p_code); d text := prepay__digits(p_q); q text := btrim(coalesce(p_q, ''));
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  if length(d) < 4 and length(q) < 2 then return jsonb_build_object('ok', true, 'rows', '[]'::jsonb); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(x order by x->>'name') from (
      select jsonb_build_object('id', c.id, 'phone', c.phone, 'name', c.name, 'has_pin', c.pin_hash is not null,
                                'balance', prepay__balance(c.id)) x
      from prepay_customers c
      where (length(d) >= 4 and c.phone like '%' || d)
         or (length(d) < 4 and c.name ilike '%' || q || '%')
      limit 20) t), '[]'::jsonb));
end $$;

-- 손님 한 명: 잔액·환불 가능액·내역
create or replace function prepay_customer(p_branch uuid, p_code text, p_customer uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(p_branch, p_code); c prepay_customers; bal int; bon int;
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  select * into c from prepay_customers where id = p_customer;
  if not found then return jsonb_build_object('ok', false, 'error', '손님을 못 찾았어요'); end if;
  bal := prepay__balance(c.id);
  select coalesce(sum(bonus), 0) into bon from prepay_ledger where customer_id = c.id;
  return jsonb_build_object('ok', true, 'role', r,
    'customer', jsonb_build_object('id', c.id, 'phone', c.phone, 'name', c.name, 'memo', c.memo, 'has_pin', c.pin_hash is not null, 'created_at', c.created_at),
    'balance', bal, 'bonus_left', bon, 'refundable', greatest(0, bal - bon),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'amount', l.amount, 'paid', l.paid, 'bonus', l.bonus,
        'branch_id', l.branch_id, 'staff_name', l.staff_name, 'by_owner', l.by_owner, 'cancel_of', l.cancel_of, 'memo', l.memo, 'created_at', l.created_at,
        'canceled', exists(select 1 from prepay_ledger z where z.cancel_of = l.id)) order by l.created_at desc)
      from prepay_ledger l where l.customer_id = c.id), '[]'::jsonb));
end $$;

-- 충전 (처음 손님이면 새로 등록). p_pin: 손님이 정하는 조회 비밀번호(선택)
create or replace function prepay_charge(p_branch uuid, p_code text, p_staff uuid, p_phone text, p_name text, p_paid int, p_pin text, p_memo text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := prepay__auth(p_branch, p_code); ph text := prepay__digits(p_phone); s prepay_settings; cid uuid; bon int := 0;
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  if ph !~ '^01[0-9]{8,9}$' then return jsonb_build_object('ok', false, 'error', '휴대폰 번호를 010으로 시작하는 숫자로 넣어 주세요'); end if;
  if p_paid is null or p_paid < 1000 or p_paid > 10000000 then return jsonb_build_object('ok', false, 'error', '충전 금액은 1,000원 ~ 1,000만원'); end if;
  if p_pin is not null and p_pin <> '' and p_pin !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', '손님 비밀번호는 숫자 4자리'); end if;
  select * into s from prepay_settings where id = 1;
  if p_paid >= s.bonus_min then bon := floor(p_paid * s.bonus_rate / 100)::int; end if;
  select id into cid from prepay_customers where phone = ph for update;
  if cid is null then
    insert into prepay_customers (phone, name, pin_hash, created_branch)
    values (ph, nullif(btrim(coalesce(p_name, '')), ''), case when coalesce(p_pin, '') <> '' then crypt(p_pin, gen_salt('bf')) end, p_branch)
    returning id into cid;
  else
    update prepay_customers set
      name = coalesce(nullif(btrim(coalesce(p_name, '')), ''), name),
      pin_hash = case when coalesce(p_pin, '') <> '' then crypt(p_pin, gen_salt('bf')) else pin_hash end
    where id = cid;
  end if;
  insert into prepay_ledger (customer_id, kind, amount, paid, bonus, branch_id, staff_id, staff_name, by_owner, memo)
  values (cid, 'charge', p_paid + bon, p_paid, bon, p_branch, p_staff, prepay__staff_name(p_staff), r = 'owner', nullif(btrim(coalesce(p_memo, '')), ''));
  return jsonb_build_object('ok', true, 'customer_id', cid, 'bonus', bon, 'balance', prepay__balance(cid));
end $$;

-- 사용 (잔액 넘게 못 씀)
create or replace function prepay_use(p_branch uuid, p_code text, p_staff uuid, p_customer uuid, p_amount int, p_memo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(p_branch, p_code); bal int;
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  if p_amount is null or p_amount < 1 then return jsonb_build_object('ok', false, 'error', '사용 금액을 넣어 주세요'); end if;
  perform 1 from prepay_customers where id = p_customer for update;   -- 동시에 두 번 빼지 않게
  if not found then return jsonb_build_object('ok', false, 'error', '손님을 못 찾았어요'); end if;
  bal := prepay__balance(p_customer);
  if p_amount > bal then return jsonb_build_object('ok', false, 'error', '잔액이 모자라요 (남은 돈 ' || to_char(bal, 'FM999,999,999') || '원)'); end if;
  insert into prepay_ledger (customer_id, kind, amount, branch_id, staff_id, staff_name, by_owner, memo)
  values (p_customer, 'use', -p_amount, p_branch, p_staff, prepay__staff_name(p_staff), r = 'owner', nullif(btrim(coalesce(p_memo, '')), ''));
  return jsonb_build_object('ok', true, 'balance', bal - p_amount);
end $$;

-- 취소: 반대 줄을 새로 남김. 매장 코드는 오늘 우리 매장 충전·사용만, 사장님 코드는 전부
create or replace function prepay_cancel(p_branch uuid, p_code text, p_staff uuid, p_ledger uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(p_branch, p_code); l prepay_ledger; bal int;
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  select * into l from prepay_ledger where id = p_ledger;
  if not found then return jsonb_build_object('ok', false, 'error', '기록을 못 찾았어요'); end if;
  if l.kind = 'cancel' then return jsonb_build_object('ok', false, 'error', '취소 기록은 다시 취소할 수 없어요'); end if;
  if exists(select 1 from prepay_ledger where cancel_of = l.id) then return jsonb_build_object('ok', false, 'error', '이미 취소했어요'); end if;
  if r <> 'owner' then
    if l.kind not in ('charge', 'use') or l.branch_id is distinct from p_branch or (l.created_at at time zone 'Asia/Seoul')::date <> prepay__today_kst() then
      return jsonb_build_object('ok', false, 'error', '오늘 우리 매장의 충전·사용만 취소할 수 있어요. 그 밖의 건 사장님께 말해 주세요');
    end if;
  end if;
  perform 1 from prepay_customers where id = l.customer_id for update;
  bal := prepay__balance(l.customer_id);
  if bal - l.amount < 0 then return jsonb_build_object('ok', false, 'error', '이미 쓴 돈이 있어서 이 충전을 취소하면 잔액이 마이너스가 돼요'); end if;
  insert into prepay_ledger (customer_id, kind, amount, paid, bonus, branch_id, staff_id, staff_name, by_owner, cancel_of, memo)
  values (l.customer_id, 'cancel', -l.amount, -l.paid, -l.bonus, p_branch, p_staff, prepay__staff_name(p_staff), r = 'owner', l.id, nullif(btrim(coalesce(p_reason, '')), ''));
  return jsonb_build_object('ok', true, 'balance', bal - l.amount);
end $$;

-- 손님 조회 비밀번호·이름 바꾸기 (계산대에서 손님이 직접 입력)
create or replace function prepay_set_customer(p_branch uuid, p_code text, p_customer uuid, p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := prepay__auth(p_branch, p_code);
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  if p_pin is not null and p_pin <> '' and p_pin !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', '손님 비밀번호는 숫자 4자리'); end if;
  update prepay_customers set
    name = coalesce(nullif(btrim(coalesce(p_name, '')), ''), name),
    pin_hash = case when coalesce(p_pin, '') <> '' then crypt(p_pin, gen_salt('bf')) else pin_hash end,
    fail_count = case when coalesce(p_pin, '') <> '' then 0 else fail_count end,
    locked_until = case when coalesce(p_pin, '') <> '' then null else locked_until end
  where id = p_customer;
  if not found then return jsonb_build_object('ok', false, 'error', '손님을 못 찾았어요'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 기록 목록 (합계 계산용). 매장 코드는 우리 매장만, 사장님 코드는 전 매장
create or replace function prepay_report(p_branch uuid, p_code text, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(p_branch, p_code);
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  return jsonb_build_object('ok', true, 'role', r, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', l.id, 'customer_id', l.customer_id, 'name', c.name, 'phone', c.phone,
      'kind', l.kind, 'amount', l.amount, 'paid', l.paid, 'bonus', l.bonus, 'branch_id', l.branch_id, 'staff_name', l.staff_name,
      'by_owner', l.by_owner, 'cancel_of', l.cancel_of, 'memo', l.memo, 'created_at', l.created_at,
      'orig_kind', (select o.kind from prepay_ledger o where o.id = l.cancel_of),   -- 취소 줄이면 무엇을 취소했는지
      'canceled', exists(select 1 from prepay_ledger z where z.cancel_of = l.id)) order by l.created_at desc)
    from prepay_ledger l join prepay_customers c on c.id = l.customer_id
    where (l.created_at at time zone 'Asia/Seoul')::date between p_from and p_to
      and (r = 'owner' or l.branch_id = p_branch)), '[]'::jsonb));
end $$;

-- ===== 사장님 코드만 =====
create or replace function prepay_customers_all(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(null, p_code);
begin
  if r is distinct from 'owner' then return case when r = 'locked' then prepay__err(r) else jsonb_build_object('ok', false, 'error', '사장님 코드가 필요해요') end; end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'phone', c.phone, 'name', c.name, 'has_pin', c.pin_hash is not null,
      'balance', t.bal, 'bonus_left', t.bon, 'paid', t.paid, 'last_at', t.last_at, 'created_at', c.created_at) order by t.bal desc, c.name)
    from prepay_customers c
    cross join lateral (select coalesce(sum(amount), 0)::int bal, coalesce(sum(bonus), 0)::int bon, coalesce(sum(paid), 0)::int paid, max(created_at) last_at
                        from prepay_ledger where customer_id = c.id) t), '[]'::jsonb));
end $$;

-- 환불: 적립분 빼고. 잔액·적립 합계를 0으로
create or replace function prepay_refund(p_code text, p_branch uuid, p_staff uuid, p_customer uuid, p_memo text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(null, p_code); bal int; bon int; ref int;
begin
  if r is distinct from 'owner' then return case when r = 'locked' then prepay__err(r) else jsonb_build_object('ok', false, 'error', '환불은 사장님 코드가 필요해요') end; end if;
  perform 1 from prepay_customers where id = p_customer for update;
  if not found then return jsonb_build_object('ok', false, 'error', '손님을 못 찾았어요'); end if;
  bal := prepay__balance(p_customer);
  select coalesce(sum(bonus), 0) into bon from prepay_ledger where customer_id = p_customer;
  if bal <= 0 then return jsonb_build_object('ok', false, 'error', '남은 잔액이 없어요'); end if;
  ref := greatest(0, bal - bon);
  insert into prepay_ledger (customer_id, kind, amount, paid, bonus, branch_id, staff_id, staff_name, by_owner, memo)
  values (p_customer, 'refund', -bal, -ref, -bon, p_branch, p_staff, prepay__staff_name(p_staff), true, nullif(btrim(coalesce(p_memo, '')), ''));
  return jsonb_build_object('ok', true, 'refund', ref, 'forfeit', bal - ref);
end $$;

-- 기존 앱 잔액 옮기기: p_rows = [{"phone":"010...","name":"홍길동","balance":50000}, ...]
-- 이미 '옮기기' 기록이 있는 번호는 건너뜀 (두 번 붙여넣어도 두 배가 안 되게)
create or replace function prepay_import(p_code text, p_branch uuid, p_staff uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(null, p_code); x jsonb; ph text; amt int; cid uuid; added int := 0; skipped int := 0; bad int := 0;
begin
  if r is distinct from 'owner' then return case when r = 'locked' then prepay__err(r) else jsonb_build_object('ok', false, 'error', '옮기기는 사장님 코드가 필요해요') end; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    ph := prepay__digits(x->>'phone');
    amt := floor(coalesce(nullif(x->>'balance', '')::numeric, 0))::int;
    if ph !~ '^01[0-9]{8,9}$' or amt < 0 then bad := bad + 1; continue; end if;
    select id into cid from prepay_customers where phone = ph;
    if cid is null then
      insert into prepay_customers (phone, name, created_branch, memo) values (ph, nullif(btrim(coalesce(x->>'name', '')), ''), p_branch, '기존 앱에서 옮김') returning id into cid;
    elsif exists(select 1 from prepay_ledger where customer_id = cid and kind = 'import') then
      skipped := skipped + 1; continue;
    end if;
    if amt > 0 then
      insert into prepay_ledger (customer_id, kind, amount, paid, bonus, branch_id, staff_id, staff_name, by_owner, memo)
      values (cid, 'import', amt, amt, 0, p_branch, p_staff, prepay__staff_name(p_staff), true, '기존 앱 잔액');
    else
      insert into prepay_ledger (customer_id, kind, amount, paid, bonus, branch_id, staff_id, staff_name, by_owner, memo)
      values (cid, 'import', 0, 0, 0, p_branch, p_staff, prepay__staff_name(p_staff), true, '기존 앱 잔액 0');
    end if;
    added := added + 1;
  end loop;
  return jsonb_build_object('ok', true, 'added', added, 'skipped', skipped, 'bad', bad);
end $$;

-- 코드 바꾸기: p_branch 가 null 이면 사장님 코드, 아니면 그 매장 코드
create or replace function prepay_set_code(p_owner_code text, p_branch uuid, p_new_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := prepay__auth(null, p_owner_code);
begin
  if r is distinct from 'owner' then return case when r = 'locked' then prepay__err(r) else jsonb_build_object('ok', false, 'error', '사장님 코드가 틀려요') end; end if;
  if coalesce(p_new_code, '') !~ '^[0-9]{6}$' then return jsonb_build_object('ok', false, 'error', '숫자 6자리로 정해 주세요'); end if;
  if p_branch is null then
    update prepay_settings set owner_code_hash = crypt(p_new_code, gen_salt('bf')), updated_at = now() where id = 1;
  else
    if exists(select 1 from prepay_branch_codes b where b.branch_id <> p_branch and b.code_hash = crypt(p_new_code, b.code_hash))
       or (select owner_code_hash = crypt(p_new_code, owner_code_hash) from prepay_settings where id = 1) then
      return jsonb_build_object('ok', false, 'error', '다른 매장이나 사장님 코드와 같은 숫자는 쓸 수 없어요');
    end if;
    insert into prepay_branch_codes (branch_id, code_hash, updated_at) values (p_branch, crypt(p_new_code, gen_salt('bf')), now())
    on conflict (branch_id) do update set code_hash = excluded.code_hash, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- 적립 규칙 바꾸기
create or replace function prepay_set_bonus(p_code text, p_min int, p_rate numeric) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(null, p_code);
begin
  if r is distinct from 'owner' then return case when r = 'locked' then prepay__err(r) else jsonb_build_object('ok', false, 'error', '사장님 코드가 필요해요') end; end if;
  if p_min is null or p_min < 0 or p_rate is null or p_rate < 0 or p_rate > 50 then return jsonb_build_object('ok', false, 'error', '기준 금액·비율을 확인해 주세요'); end if;
  update prepay_settings set bonus_min = p_min, bonus_rate = p_rate, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;

-- ===== 손님용 (prepay.html): 번호 + 손님 비밀번호 4자리 =====
create or replace function prepay_my(p_phone text, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare ph text := prepay__digits(p_phone); c prepay_customers;
begin
  select * into c from prepay_customers where phone = ph for update;
  if not found or c.pin_hash is null then
    return jsonb_build_object('ok', false, 'error', '등록된 번호가 없거나 조회 비밀번호를 아직 안 정했어요. 매장에서 정해 드려요');
  end if;
  if c.locked_until is not null and c.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', '비밀번호를 여러 번 틀려서 10분 동안 잠겼어요');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' or c.pin_hash <> crypt(p_pin, c.pin_hash) then
    -- 5번 틀리면 10분 잠금 (잠금이 걸리면 횟수는 처음부터 다시 셈)
    update prepay_customers set
      locked_until = case when fail_count + 1 >= 5 then now() + interval '10 minutes' else null end,
      fail_count = case when fail_count + 1 >= 5 then 0 else fail_count + 1 end
    where id = c.id;
    return jsonb_build_object('ok', false, 'error', '비밀번호가 틀려요');
  end if;
  update prepay_customers set fail_count = 0, locked_until = null where id = c.id;
  return jsonb_build_object('ok', true, 'name', c.name, 'balance', prepay__balance(c.id),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'amount', l.amount, 'bonus', l.bonus,
        'branch', b.name, 'created_at', l.created_at) order by l.created_at desc)
      from (select * from prepay_ledger where customer_id = c.id order by created_at desc limit 50) l
      left join manual_branches b on b.id = l.branch_id), '[]'::jsonb));
end $$;

-- 내부 도우미는 앱에서 못 부르게
revoke execute on function prepay__auth(uuid, text) from public, anon, authenticated;
revoke execute on function prepay__balance(uuid) from public, anon, authenticated;
revoke execute on function prepay__staff_name(uuid) from public, anon, authenticated;

select '선결제 준비 완료 — 앱의 선결제 화면에서 사장님 코드를 정해 주세요' as 결과;
