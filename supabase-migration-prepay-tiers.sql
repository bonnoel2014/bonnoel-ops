-- 선결제 적립 두 단계 (10만원 이상 10% · 미만 5%) — 이것만 실행하면 돼요. 여러 번 실행해도 안전.
alter table prepay_settings add column if not exists base_rate numeric not null default 0;

create or replace function prepay_status() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'ready', (select owner_code_hash is not null from prepay_settings where id = 1),
    'bonus_min', (select bonus_min from prepay_settings where id = 1),
    'bonus_rate', (select bonus_rate from prepay_settings where id = 1),
    'base_rate', (select base_rate from prepay_settings where id = 1),
    'branches', coalesce((select jsonb_agg(branch_id) from prepay_branch_codes), '[]'::jsonb))
$$;

create or replace function prepay_charge(p_branch uuid, p_code text, p_staff uuid, p_phone text, p_name text, p_paid int, p_pin text, p_memo text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := prepay__auth(p_branch, p_code); ph text := prepay__digits(p_phone); s prepay_settings; cid uuid; bon int := 0;
begin
  if r is null or r = 'locked' then return prepay__err(r); end if;
  if ph !~ '^01[0-9]{8,9}$' then return jsonb_build_object('ok', false, 'error', '휴대폰 번호를 010으로 시작하는 숫자로 넣어 주세요'); end if;
  if p_paid is null or p_paid < 1000 or p_paid > 10000000 then return jsonb_build_object('ok', false, 'error', '충전 금액은 1,000원 ~ 1,000만원'); end if;
  if p_pin is not null and p_pin <> '' and p_pin !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', '손님 비밀번호는 숫자 4자리'); end if;
  select * into s from prepay_settings where id = 1;
  if p_paid >= s.bonus_min then bon := floor(p_paid * s.bonus_rate / 100)::int; else bon := floor(p_paid * s.base_rate / 100)::int; end if;
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

drop function if exists prepay_set_bonus(text, int, numeric);
create or replace function prepay_set_bonus(p_code text, p_min int, p_rate numeric, p_base numeric default 0) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r text := prepay__auth(null, p_code);
begin
  if r is distinct from 'owner' then return case when r = 'locked' then prepay__err(r) else jsonb_build_object('ok', false, 'error', '사장님 코드가 필요해요') end; end if;
  if p_min is null or p_min < 0 or p_rate is null or p_rate < 0 or p_rate > 50 or p_base is null or p_base < 0 or p_base > 50 then return jsonb_build_object('ok', false, 'error', '기준 금액·비율을 확인해 주세요'); end if;
  update prepay_settings set bonus_min = p_min, bonus_rate = p_rate, base_rate = p_base, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;

select '적립 두 단계 준비 완료 — 앱 선결제 관리 > 설정에서 100000 / 10 / 5 를 저장해 주세요' as 결과;
