-- 리뷰 뽑기판 v2-10: 9등으로 확장 (맛보기 파운드 · 다음 방문 1,000원/500원 할인 · 한 번 더 뽑기) — draw10.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 520알 배분: 1등 1 · 2등 3 · 3등 16 · 4등 60 · 5등 120 · 6등 80 · 7등 60 · 8등 60 · 9등 120  (사장님 앱에서 바꿀 수 있음, 새 판부터 적용)
-- 받는 방식(kind): instant(즉시) / coupon(다음 방문 쿠폰 3주) / redraw(한 번 더 뽑기)
-- 지금 열려 있는 5등짜리 판은 닫고, 다음 뽑기부터 9등 판이 새로 시작된다.

create table if not exists draw_config (
  id int primary key default 1 check (id = 1),
  counts int[] not null default '{1,3,16,60,120,80,60,60,120}',
  kinds text[] not null default '{instant,instant,instant,instant,instant,instant,coupon,redraw,coupon}',
  updated_at timestamptz not null default now()
);
insert into draw_config (id) values (1) on conflict (id) do nothing;
alter table draw_config enable row level security;
revoke all on draw_config from anon;
grant select, update on draw_config to authenticated;
drop policy if exists owner_only on draw_config;
create policy owner_only on draw_config for all to authenticated using (owner__is()) with check (owner__is());

alter table draw_logs add column if not exists redraw_of uuid;
alter table draw_logs add column if not exists prize_kind text not null default 'instant';
alter table draw_logs drop constraint if exists draw_logs_rank_check;
alter table draw_logs add constraint draw_logs_rank_check check (rank between 1 and 20);

-- 상품표 6~9등 채우기 (없는 매장만)
update draw_prizes set labels = labels || '{"6":"맛보기 파운드","7":"다음 방문 시 1,000원 할인","8":"한 번 더 뽑기","9":"다음 방문 시 500원 할인"}'::jsonb, updated_at = now()
where coalesce(labels ->> '6', '') = '';

-- 지금 판 닫기 → 다음 뽑기부터 9등 판
update draw_boards set closed_at = now(), closed_by = 'owner' where closed_at is null;

create or replace function draw__open_board(p_branch uuid) returns draw_boards
language plpgsql security definer set search_path = public as $$
declare b draw_boards; n int; cnt int[];
begin
  select * into b from draw_boards where branch_id = p_branch and closed_at is null order by started_at desc limit 1;
  if b.id is null then
    select coalesce(max(seq), 0) + 1 into n from draw_boards where branch_id = p_branch;
    select counts into cnt from draw_config where id = 1;
    insert into draw_boards (branch_id, seq, remaining) values (p_branch, n, coalesce(cnt, '{1,3,16,60,120,80,60,60,120}')) returning * into b;
  end if;
  return b;
end $$;

create or replace function draw_prizes_get(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true,
    'labels', coalesce((select labels from draw_prizes where branch_id = p_branch), '{}'::jsonb),
    'links', coalesce((select review_links from draw_prizes where branch_id = p_branch), '{}'::jsonb),
    'kinds', coalesce((select to_jsonb(kinds) from draw_config where id = 1), '[]'::jsonb),
    'counts', coalesce((select to_jsonb(counts) from draw_config where id = 1), '[]'::jsonb))
$$;

create or replace function draw_prizes_set(p_branch uuid, p_staff uuid, p_pin text, p_labels jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s manual_staff; k int; n int;
begin
  select * into s from manual_staff where id = p_staff and coalesce(active, true);
  if s.id is null or s.role not in ('manager', 'owner') then return draw__err('매니저나 사장님만 바꿀 수 있어요'); end if;
  if s.role <> 'owner' and s.branch_id is not null and s.branch_id <> p_branch then return draw__err('우리 매장 상품표만 바꿀 수 있어요'); end if;
  if s.pin is null or s.pin <> coalesce(p_pin, '') then return draw__err('비밀번호가 틀려요'); end if;
  select array_length(counts, 1) into n from draw_config where id = 1;
  for k in 1..coalesce(n, 9) loop
    if coalesce(trim(p_labels ->> k::text), '') = '' then return draw__err(k || '등 상품이 비어 있어요'); end if;
  end loop;
  insert into draw_prizes (branch_id, labels, updated_at, updated_by)
  values (p_branch, p_labels, now(), s.name)
  on conflict (branch_id) do update set labels = excluded.labels, updated_at = now(), updated_by = excluded.updated_by;
  return jsonb_build_object('ok', true);
end $$;

-- 공통 뽑기: 등수 수는 판의 배열 길이, kind별 기한, 한 번 더 뽑기(p_redraw) 처리
drop function if exists draw__pick_core(uuid, int, text, uuid, text, text, text, text, boolean, text);
create or replace function draw__pick_core(p_branch uuid, p_cell int, p_method text, p_staff uuid, p_source text, p_device text, p_ip text, p_phone text, p_marketing boolean, p_review text, p_redraw uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k int; m text; c int; code text; exp timestamptz; rv text; nr int; kinds text[]; kd text; rd draw_logs;
begin
  m := case when p_method in ('board', 'capsule', 'claw', 'hunt') then p_method else 'board' end;
  rv := case when p_review in ('naver', 'google', 'kakao', 'tmap') then p_review else null end;
  if p_cell is not null and (p_cell < 0 or p_cell > 519) then return draw__err('칸 번호가 이상해요'); end if;

  -- 한 번 더 뽑기: 당첨 기록이 맞는지 확인하고 사용 처리
  if p_redraw is not null then
    select * into rd from draw_logs where id = p_redraw for update;
    if rd.id is null or rd.prize_kind <> 'redraw' then return draw__err('한 번 더 뽑기 기록을 못 찾았어요'); end if;
    if rd.status <> 'pending' then return draw__err('이미 쓴 "한 번 더 뽑기"예요'); end if;
    if p_source = 'guest' and not (rd.device_id = p_device or (rd.phone is not null and rd.phone = p_phone)) then return draw__err('이 폰(번호)의 "한 번 더 뽑기"가 아니에요'); end if;
    update draw_logs set status = 'given', done_at = now(), done_by = 'redraw' where id = rd.id;
  end if;

  perform draw__expire(p_branch);
  b := draw__open_board(p_branch);
  select * into b from draw_boards where id = b.id for update;
  if b.closed_at is not null then b := draw__open_board(p_branch); select * into b from draw_boards where id = b.id for update; end if;
  nr := array_length(b.remaining, 1);
  select coalesce(d.kinds, '{}') into kinds from draw_config d where d.id = 1;

  select labels into lb from draw_prizes where branch_id = p_branch;
  for k in 1..nr loop
    if coalesce(trim(lb ->> k::text), '') = '' then return draw__err('상품표 ' || k || '등이 비어 있어요 (뽑기 상품표 메뉴)'); end if;
  end loop;

  c := p_cell;
  if c is null then
    select s into c from generate_series(0, 519) s where not (s = any(b.taken)) order by random() limit 1;
    if c is null then return draw__err('판이 비어 있어요. 잠시 뒤 다시 해 주세요'); end if;
  elsif c = any(b.taken) then
    return draw__err('이미 뽑힌 칸이에요. 다른 칸을 눌러 주세요');
  end if;

  total := 0; for k in 1..nr loop total := total + b.remaining[k]; end loop;
  if total <= 0 then return draw__err('판이 비어 있어요. 잠시 뒤 다시 해 주세요'); end if;
  pick := floor(random() * total)::int + 1;
  acc := 0; r := nr;
  for k in 1..nr loop
    acc := acc + b.remaining[k];
    if pick <= acc then r := k; exit; end if;
  end loop;
  kd := coalesce(kinds[r], 'instant');

  b.remaining[r] := b.remaining[r] - 1;
  update draw_boards set remaining = b.remaining, taken = array_append(taken, c) where id = b.id;
  if p_source = 'guest' then
    code := array_to_string(array(select substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random() * 32)::int + 1, 1) from generate_series(1, 4)), '');
    if p_phone is not null then
      exp := case when kd = 'coupon' then now() + interval '21 days' else ((now() at time zone 'Asia/Seoul')::date + 1)::timestamp at time zone 'Asia/Seoul' end;
    end if;
  end if;
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id, method, source, device_id, ip, confirm_code, phone, consent_at, marketing_ok, coupon_expires_at, review_source, redraw_of, prize_kind, is_test)
  values (b.id, p_branch, c, r, lb ->> r::text, p_staff, m, p_source, p_device, p_ip, code, p_phone, case when p_phone is not null then now() end, coalesce(p_marketing, false), exp, rv, p_redraw, kd, coalesce(rd.is_test, false)) returning * into lg;

  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'kind', kd, 'cell', c, 'method', m, 'code', code, 'drawn_at', lg.drawn_at,
    'expires_at', exp, 'phone_masked', draw__mask(p_phone), 'branch', (select name from manual_branches where id = p_branch), 'is_test', coalesce(rd.is_test, false));
end $$;

drop function if exists draw_pick(uuid, uuid, int, text);
create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int, p_method text default 'board', p_redraw uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  return draw__pick_core(p_branch, p_cell, p_method, p_staff, 'staff', null, null, null, false, null, p_redraw);
end $$;

drop function if exists draw_guest_pick(uuid, text, text, int, text, boolean, boolean, text);
create or replace function draw_guest_pick(p_branch uuid, p_device text, p_method text, p_cell int, p_phone text, p_consent boolean, p_marketing boolean default false, p_review text default null, p_redraw uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ip text; n int; today_from timestamptz; ph text; is_t boolean; res jsonb; is_redraw boolean := false;
begin
  if coalesce(p_device, '') = '' or length(p_device) > 80 then return draw__err('브라우저를 새로고침한 뒤 다시 해 주세요'); end if;
  if not exists (select 1 from manual_branches where id = p_branch) then return draw__err('매장을 찾을 수 없어요. QR을 다시 찍어 주세요'); end if;
  ph := draw__digits(p_phone);
  if ph !~ '^01[0-9]{8,9}$' then return draw__err('휴대폰 번호를 다시 확인해 주세요 (예: 010-1234-5678)'); end if;
  if not coalesce(p_consent, false) then return draw__err('개인정보 수집·이용에 동의해야 참여할 수 있어요'); end if;
  is_t := exists (select 1 from draw_test_phones where phone = ph);
  if p_redraw is not null then
    is_redraw := exists (select 1 from draw_logs where id = p_redraw and prize_kind = 'redraw' and status = 'pending' and (device_id = p_device or phone = ph));
    if not is_redraw then return draw__err('"한 번 더 뽑기"를 못 찾았거나 이미 썼어요'); end if;
  end if;
  begin v_ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); exception when others then v_ip := null; end;
  if not is_t and not is_redraw then
    today_from := (now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul';
    select count(*) into n from draw_logs where source = 'guest' and phone = ph and drawn_at >= today_from and status <> 'cancelled' and not is_test and redraw_of is null;
    if n >= 1 then return draw__err('오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
    select count(*) into n from draw_logs where source = 'guest' and device_id = p_device and drawn_at >= today_from and status <> 'cancelled' and not is_test and redraw_of is null;
    if n >= 1 then return draw__err('이 폰으로 오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
    if coalesce(v_ip, '') <> '' then
      select count(*) into n from draw_logs l where l.source = 'guest' and l.ip = v_ip and l.drawn_at >= today_from and l.status <> 'cancelled' and not l.is_test and l.redraw_of is null;
      if n >= 6 then return draw__err('같은 인터넷에서 너무 많이 뽑았어요. 직원에게 말씀해 주세요'); end if;
    end if;
  end if;
  res := draw__pick_core(p_branch, p_cell, p_method, null, 'guest', p_device, nullif(v_ip, ''), ph, p_marketing, p_review, p_redraw);
  if is_t and (res ->> 'ok') = 'true' then
    update draw_logs set is_test = true where id = (res ->> 'log_id')::uuid;
    res := res || '{"is_test": true}'::jsonb;
  end if;
  return res;
end $$;

-- 손님 폰 상태·찾기·매장폰 목록에 kind 포함
create or replace function draw_guest_status(p_log uuid, p_device text, p_phone text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg draw_logs;
begin
  select * into lg from draw_logs where id = p_log and source = 'guest' and (device_id = p_device or (phone is not null and phone = draw__digits(p_phone)));
  if lg.id is null then return draw__err('기록을 못 찾았어요'); end if;
  if lg.status = 'pending' and lg.coupon_expires_at is not null and lg.coupon_expires_at < now() then update draw_logs set status = 'expired' where id = lg.id; lg.status := 'expired'; end if;
  return jsonb_build_object('ok', true, 'status', lg.status, 'rank', lg.rank, 'prize', lg.prize_label, 'kind', lg.prize_kind, 'code', lg.confirm_code, 'drawn_at', lg.drawn_at, 'substitute', lg.substitute,
    'expires_at', lg.coupon_expires_at, 'phone_masked', draw__mask(lg.phone), 'branch', (select name from manual_branches where id = lg.branch_id), 'branch_id', lg.branch_id, 'done_at', lg.done_at, 'done_by', lg.done_by);
end $$;

create or replace function draw_coupon_find(p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ph text;
begin
  ph := draw__digits(p_phone);
  if ph !~ '^01[0-9]{8,9}$' then return draw__err('휴대폰 번호를 다시 확인해 주세요'); end if;
  update draw_logs set status = 'expired' where source = 'guest' and status = 'pending' and phone = ph and coupon_expires_at is not null and coupon_expires_at < now();
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', l.id, 'code', l.confirm_code, 'rank', l.rank, 'prize', l.prize_label, 'kind', l.prize_kind, 'status', l.status, 'drawn_at', l.drawn_at, 'expires_at', l.coupon_expires_at,
      'branch', b.name, 'branch_id', l.branch_id, 'done_at', l.done_at) order by l.drawn_at desc)
    from draw_logs l join manual_branches b on b.id = l.branch_id
    where l.source = 'guest' and l.phone = ph and (l.status = 'pending' or (l.status in ('given', 'substituted', 'expired') and l.drawn_at > now() - interval '30 days'))), '[]'::jsonb));
end $$;

create or replace function draw_coupon_lookup(p_branch uuid, p_staff uuid, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q text; d text;
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  perform draw__expire(p_branch);
  q := upper(trim(coalesce(p_q, ''))); d := draw__digits(q);
  if length(q) < 4 then return draw__err('코드 4글자 또는 번호 뒤 4자리 이상 넣어 주세요'); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'code', confirm_code, 'rank', rank, 'prize', prize_label, 'kind', prize_kind, 'status', status, 'method', method, 'drawn_at', drawn_at,
      'expires_at', coupon_expires_at, 'phone_masked', draw__mask(phone)) order by drawn_at desc)
    from (select * from draw_logs where branch_id = p_branch and source = 'guest' and status in ('pending', 'expired')
          and (confirm_code = q or (length(d) >= 4 and phone is not null and phone like '%' || d)) order by drawn_at desc limit 20) x), '[]'::jsonb));
end $$;

create or replace function draw_guest_pending(p_branch uuid, p_staff uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  perform draw__expire(p_branch);
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'code', confirm_code, 'rank', rank, 'prize', prize_label, 'kind', prize_kind, 'status', status, 'method', method, 'drawn_at', drawn_at,
      'expires_at', coupon_expires_at, 'phone_masked', draw__mask(phone)) order by drawn_at desc)
    from draw_logs where branch_id = p_branch and source = 'guest' and status in ('pending', 'expired') and drawn_at > now() - interval '24 hours'), '[]'::jsonb));
end $$;

revoke all on function draw__pick_core(uuid, int, text, uuid, text, text, text, text, boolean, text, uuid) from public, anon, authenticated;
grant execute on function draw_pick(uuid, uuid, int, text, uuid), draw_guest_pick(uuid, text, text, int, text, boolean, boolean, text, uuid), draw_prizes_get(uuid), draw_prizes_set(uuid, uuid, text, jsonb),
  draw_guest_status(uuid, text, text), draw_coupon_find(text), draw_coupon_lookup(uuid, uuid, text), draw_guest_pending(uuid, uuid) to anon, authenticated;

-- ===== 하루 20명 한정 (매장별, 테스트·한 번 더 뽑기 제외) =====
alter table draw_config add column if not exists daily_limit int not null default 20;

create or replace function draw__today_count(p_branch uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from draw_logs
  where branch_id = p_branch and status <> 'cancelled' and not is_test and redraw_of is null
    and drawn_at >= ((now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul')
$$;

create or replace function draw_prizes_get(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true,
    'labels', coalesce((select labels from draw_prizes where branch_id = p_branch), '{}'::jsonb),
    'links', coalesce((select review_links from draw_prizes where branch_id = p_branch), '{}'::jsonb),
    'kinds', coalesce((select to_jsonb(kinds) from draw_config where id = 1), '[]'::jsonb),
    'counts', coalesce((select to_jsonb(counts) from draw_config where id = 1), '[]'::jsonb),
    'daily_limit', coalesce((select daily_limit from draw_config where id = 1), 20),
    'today_left', greatest(0, coalesce((select daily_limit from draw_config where id = 1), 20) - draw__today_count(p_branch)))
$$;

create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int, p_method text default 'board', p_redraw uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lim int;
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  select daily_limit into lim from draw_config where id = 1;
  if p_redraw is null and draw__today_count(p_branch) >= coalesce(lim, 20) then return draw__err('오늘 ' || coalesce(lim, 20) || '명이 다 찼어요. 내일 또 해 주세요 (하루 ' || coalesce(lim, 20) || '명 한정)'); end if;
  return draw__pick_core(p_branch, p_cell, p_method, p_staff, 'staff', null, null, null, false, null, p_redraw);
end $$;

create or replace function draw_guest_pick(p_branch uuid, p_device text, p_method text, p_cell int, p_phone text, p_consent boolean, p_marketing boolean default false, p_review text default null, p_redraw uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ip text; n int; today_from timestamptz; ph text; is_t boolean; res jsonb; is_redraw boolean := false; lim int;
begin
  if coalesce(p_device, '') = '' or length(p_device) > 80 then return draw__err('브라우저를 새로고침한 뒤 다시 해 주세요'); end if;
  if not exists (select 1 from manual_branches where id = p_branch) then return draw__err('매장을 찾을 수 없어요. QR을 다시 찍어 주세요'); end if;
  ph := draw__digits(p_phone);
  if ph !~ '^01[0-9]{8,9}$' then return draw__err('휴대폰 번호를 다시 확인해 주세요 (예: 010-1234-5678)'); end if;
  if not coalesce(p_consent, false) then return draw__err('개인정보 수집·이용에 동의해야 참여할 수 있어요'); end if;
  is_t := exists (select 1 from draw_test_phones where phone = ph);
  if p_redraw is not null then
    is_redraw := exists (select 1 from draw_logs where id = p_redraw and prize_kind = 'redraw' and status = 'pending' and (device_id = p_device or phone = ph));
    if not is_redraw then return draw__err('"한 번 더 뽑기"를 못 찾았거나 이미 썼어요'); end if;
  end if;
  begin v_ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); exception when others then v_ip := null; end;
  if not is_t and not is_redraw then
    select daily_limit into lim from draw_config where id = 1;
    if draw__today_count(p_branch) >= coalesce(lim, 20) then return draw__err('오늘 ' || coalesce(lim, 20) || '명이 다 찼어요 😢 내일 또 와 주세요 (하루 ' || coalesce(lim, 20) || '명 한정)'); end if;
    today_from := (now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul';
    select count(*) into n from draw_logs where source = 'guest' and phone = ph and drawn_at >= today_from and status <> 'cancelled' and not is_test and redraw_of is null;
    if n >= 1 then return draw__err('오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
    select count(*) into n from draw_logs where source = 'guest' and device_id = p_device and drawn_at >= today_from and status <> 'cancelled' and not is_test and redraw_of is null;
    if n >= 1 then return draw__err('이 폰으로 오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
    if coalesce(v_ip, '') <> '' then
      select count(*) into n from draw_logs l where l.source = 'guest' and l.ip = v_ip and l.drawn_at >= today_from and l.status <> 'cancelled' and not l.is_test and l.redraw_of is null;
      if n >= 6 then return draw__err('같은 인터넷에서 너무 많이 뽑았어요. 직원에게 말씀해 주세요'); end if;
    end if;
  end if;
  res := draw__pick_core(p_branch, p_cell, p_method, null, 'guest', p_device, nullif(v_ip, ''), ph, p_marketing, p_review, p_redraw);
  if is_t and (res ->> 'ok') = 'true' then
    update draw_logs set is_test = true where id = (res ->> 'log_id')::uuid;
    res := res || '{"is_test": true}'::jsonb;
  end if;
  return res;
end $$;

revoke all on function draw__today_count(uuid) from public, anon, authenticated;
grant execute on function draw_prizes_get(uuid), draw_pick(uuid, uuid, int, text, uuid), draw_guest_pick(uuid, text, text, int, text, boolean, boolean, text, uuid) to anon, authenticated;
