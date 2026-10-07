-- 리뷰 뽑기판 v2-9: 테스트 번호(사장님) — draw9.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 사장님 앱에서 등록한 번호는 하루 제한(번호·기기·IP)을 안 받고, 그 뽑기는 is_test 로 표시돼 집계·손님 명단에서 빠진다.

create table if not exists draw_test_phones (
  phone text primary key,                 -- 숫자만
  memo text,
  created_at timestamptz not null default now()
);
alter table draw_test_phones enable row level security;
revoke all on draw_test_phones from anon;
grant select, insert, update, delete on draw_test_phones to authenticated;
drop policy if exists owner_only on draw_test_phones;
create policy owner_only on draw_test_phones for all to authenticated using (owner__is()) with check (owner__is());

alter table draw_logs add column if not exists is_test boolean not null default false;

create or replace function draw_guest_pick(p_branch uuid, p_device text, p_method text, p_cell int, p_phone text, p_consent boolean, p_marketing boolean default false, p_review text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ip text; n int; today_from timestamptz; ph text; is_t boolean; res jsonb;
begin
  if coalesce(p_device, '') = '' or length(p_device) > 80 then return draw__err('브라우저를 새로고침한 뒤 다시 해 주세요'); end if;
  if not exists (select 1 from manual_branches where id = p_branch) then return draw__err('매장을 찾을 수 없어요. QR을 다시 찍어 주세요'); end if;
  ph := draw__digits(p_phone);
  if ph !~ '^01[0-9]{8,9}$' then return draw__err('휴대폰 번호를 다시 확인해 주세요 (예: 010-1234-5678)'); end if;
  if not coalesce(p_consent, false) then return draw__err('개인정보 수집·이용에 동의해야 참여할 수 있어요'); end if;
  is_t := exists (select 1 from draw_test_phones where phone = ph);
  begin v_ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); exception when others then v_ip := null; end;
  if not is_t then
    today_from := (now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul';
    select count(*) into n from draw_logs where source = 'guest' and phone = ph and drawn_at >= today_from and status <> 'cancelled' and not is_test;
    if n >= 1 then return draw__err('오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
    select count(*) into n from draw_logs where source = 'guest' and device_id = p_device and drawn_at >= today_from and status <> 'cancelled' and not is_test;
    if n >= 1 then return draw__err('이 폰으로 오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
    if coalesce(v_ip, '') <> '' then
      select count(*) into n from draw_logs l where l.source = 'guest' and l.ip = v_ip and l.drawn_at >= today_from and l.status <> 'cancelled' and not l.is_test;
      if n >= 6 then return draw__err('같은 인터넷에서 너무 많이 뽑았어요. 직원에게 말씀해 주세요'); end if;
    end if;
  end if;
  res := draw__pick_core(p_branch, p_cell, p_method, null, 'guest', p_device, nullif(v_ip, ''), ph, p_marketing, p_review);
  if is_t and (res ->> 'ok') = 'true' then
    update draw_logs set is_test = true where id = (res ->> 'log_id')::uuid;
    res := res || '{"is_test": true}'::jsonb;
  end if;
  return res;
end $$;
grant execute on function draw_guest_pick(uuid, text, text, int, text, boolean, boolean, text) to anon, authenticated;
