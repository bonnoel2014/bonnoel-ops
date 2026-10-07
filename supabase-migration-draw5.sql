-- 리뷰 뽑기판 v2-4: 손님 전화번호 + 다음 방문 쿠폰 — draw4.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 손님 폰(QR) 뽑기: 뽑기 전에 휴대폰 번호 + 개인정보 동의 필수 → 당첨은 "다음 방문 쿠폰"(3주) → 카운터에서 코드/번호로 찾아 사용 처리.
-- 번호·동의는 사장님 앱(로그인한 사장님)만 읽을 수 있음. 매장폰은 뒤 4자리 검색 결과만 봄.

alter table draw_logs add column if not exists phone text;                   -- 숫자만 (01012345678)
alter table draw_logs add column if not exists consent_at timestamptz;       -- 개인정보 수집·이용 동의 시각
alter table draw_logs add column if not exists marketing_ok boolean not null default false;   -- (선택) 소식 받기 동의
alter table draw_logs add column if not exists coupon_expires_at timestamptz;  -- 쿠폰 유효기간 (발급 + 21일)
create index if not exists draw_logs_phone on draw_logs(phone, drawn_at) where phone is not null;

create or replace function draw__digits(p text) returns text language sql immutable as $$
  select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g')
$$;
create or replace function draw__mask(p text) returns text language sql immutable as $$
  select case when length(p) = 11 then substr(p, 1, 3) || '-****-' || substr(p, 8) else p end
$$;

-- 만료: 쿠폰(번호 있는 손님 뽑기)은 유효기간 지나면 expired(알은 안 돌아감, 이미 발급된 상품).
--       번호 없는 옛 손님 뽑기(초기 버전)는 30분 뒤 expired + 알 복귀.
create or replace function draw__expire(p_branch uuid) returns void
language plpgsql security definer set search_path = public as $$
declare lg record; b draw_boards;
begin
  update draw_logs set status = 'expired' where branch_id = p_branch and source = 'guest' and status = 'pending' and phone is not null and coupon_expires_at is not null and coupon_expires_at < now();
  for lg in select * from draw_logs where branch_id = p_branch and source = 'guest' and status = 'pending' and phone is null and drawn_at < now() - interval '30 minutes' for update skip locked loop
    select * into b from draw_boards where id = lg.board_id for update;
    if b.id is not null and b.closed_at is null then
      b.remaining[lg.rank] := b.remaining[lg.rank] + 1;
      update draw_boards set remaining = b.remaining, taken = array_remove(taken, lg.cell) where id = b.id;
      update draw_logs set status = 'expired', returned = true where id = lg.id;
    else
      update draw_logs set status = 'expired' where id = lg.id;
    end if;
  end loop;
end $$;

-- 공통 뽑기 (번호·동의·쿠폰 기간 추가)
drop function if exists draw__pick_core(uuid, int, text, uuid, text, text, text);
create or replace function draw__pick_core(p_branch uuid, p_cell int, p_method text, p_staff uuid, p_source text, p_device text, p_ip text, p_phone text, p_marketing boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k text; m text; c int; code text; exp timestamptz;
begin
  m := case when p_method in ('board', 'capsule', 'claw') then p_method else 'board' end;
  if p_cell is not null and (p_cell < 0 or p_cell > 519) then return draw__err('칸 번호가 이상해요'); end if;
  select labels into lb from draw_prizes where branch_id = p_branch;
  for k in select unnest(array['1','2','3','4','5']) loop
    if coalesce(trim(lb ->> k), '') = '' then return draw__err('상품표를 먼저 채워 주세요 (뽑기 상품표 메뉴)'); end if;
  end loop;

  perform draw__expire(p_branch);
  b := draw__open_board(p_branch);
  select * into b from draw_boards where id = b.id for update;
  if b.closed_at is not null then b := draw__open_board(p_branch); select * into b from draw_boards where id = b.id for update; end if;

  c := p_cell;
  if c is null then
    select s into c from generate_series(0, 519) s where not (s = any(b.taken)) order by random() limit 1;
    if c is null then return draw__err('판이 비어 있어요. 잠시 뒤 다시 해 주세요'); end if;
  elsif c = any(b.taken) then
    return draw__err('이미 뽑힌 칸이에요. 다른 칸을 눌러 주세요');
  end if;

  total := b.remaining[1] + b.remaining[2] + b.remaining[3] + b.remaining[4] + b.remaining[5];
  if total <= 0 then return draw__err('판이 비어 있어요. 잠시 뒤 다시 해 주세요'); end if;
  pick := floor(random() * total)::int + 1;
  acc := 0; r := 5;
  for i in 1..5 loop
    acc := acc + b.remaining[i];
    if pick <= acc then r := i; exit; end if;
  end loop;

  b.remaining[r] := b.remaining[r] - 1;
  update draw_boards set remaining = b.remaining, taken = array_append(taken, c) where id = b.id;
  if p_source = 'guest' then
    code := array_to_string(array(select substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random() * 32)::int + 1, 1) from generate_series(1, 4)), '');
    if p_phone is not null then exp := now() + interval '21 days'; end if;
  end if;
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id, method, source, device_id, ip, confirm_code, phone, consent_at, marketing_ok, coupon_expires_at)
  values (b.id, p_branch, c, r, lb ->> r::text, p_staff, m, p_source, p_device, p_ip, code, p_phone, case when p_phone is not null then now() end, coalesce(p_marketing, false), exp) returning * into lg;

  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'cell', c, 'method', m, 'code', code, 'drawn_at', lg.drawn_at,
    'expires_at', exp, 'phone_masked', draw__mask(p_phone), 'branch', (select name from manual_branches where id = p_branch));
end $$;

create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int, p_method text default 'board') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  return draw__pick_core(p_branch, p_cell, p_method, p_staff, 'staff', null, null, null, false);
end $$;

-- 손님 폰 뽑기: 번호 + 동의 필수. 번호당 하루 1번(4매장 공통) · 기기당 하루 1번 · 같은 IP 하루 6번
drop function if exists draw_guest_pick(uuid, text, text, int);
create or replace function draw_guest_pick(p_branch uuid, p_device text, p_method text, p_cell int, p_phone text, p_consent boolean, p_marketing boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ip text; n int; today_from timestamptz; ph text;
begin
  if coalesce(p_device, '') = '' or length(p_device) > 80 then return draw__err('브라우저를 새로고침한 뒤 다시 해 주세요'); end if;
  if not exists (select 1 from manual_branches where id = p_branch) then return draw__err('매장을 찾을 수 없어요. QR을 다시 찍어 주세요'); end if;
  ph := draw__digits(p_phone);
  if ph !~ '^01[0-9]{8,9}$' then return draw__err('휴대폰 번호를 다시 확인해 주세요 (예: 010-1234-5678)'); end if;
  if not coalesce(p_consent, false) then return draw__err('개인정보 수집·이용에 동의해야 참여할 수 있어요'); end if;
  begin v_ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); exception when others then v_ip := null; end;
  today_from := (now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul';
  select count(*) into n from draw_logs where source = 'guest' and phone = ph and drawn_at >= today_from and status <> 'cancelled';
  if n >= 1 then return draw__err('오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
  select count(*) into n from draw_logs where source = 'guest' and device_id = p_device and drawn_at >= today_from and status <> 'cancelled';
  if n >= 1 then return draw__err('이 폰으로 오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
  if coalesce(v_ip, '') <> '' then
    select count(*) into n from draw_logs l where l.source = 'guest' and l.ip = v_ip and l.drawn_at >= today_from and l.status <> 'cancelled';
    if n >= 6 then return draw__err('같은 인터넷에서 너무 많이 뽑았어요. 직원에게 말씀해 주세요'); end if;
  end if;
  return draw__pick_core(p_branch, p_cell, p_method, null, 'guest', p_device, nullif(v_ip, ''), ph, p_marketing);
end $$;

-- 손님 폰: 내 쿠폰 상태 (기기 또는 번호가 맞아야)
create or replace function draw_guest_status(p_log uuid, p_device text, p_phone text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg draw_logs;
begin
  select * into lg from draw_logs where id = p_log and source = 'guest' and (device_id = p_device or (phone is not null and phone = draw__digits(p_phone)));
  if lg.id is null then return draw__err('기록을 못 찾았어요'); end if;
  if lg.status = 'pending' and lg.coupon_expires_at is not null and lg.coupon_expires_at < now() then update draw_logs set status = 'expired' where id = lg.id; lg.status := 'expired'; end if;
  return jsonb_build_object('ok', true, 'status', lg.status, 'rank', lg.rank, 'prize', lg.prize_label, 'code', lg.confirm_code, 'drawn_at', lg.drawn_at, 'substitute', lg.substitute,
    'expires_at', lg.coupon_expires_at, 'phone_masked', draw__mask(lg.phone), 'branch', (select name from manual_branches where id = lg.branch_id), 'branch_id', lg.branch_id, 'done_at', lg.done_at);
end $$;
drop function if exists draw_guest_status(uuid, text);

-- 손님 폰: 번호로 내 쿠폰 찾기 (안 쓴 것 + 최근 30일 쓴 것)
create or replace function draw_coupon_find(p_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare ph text;
begin
  ph := draw__digits(p_phone);
  if ph !~ '^01[0-9]{8,9}$' then return draw__err('휴대폰 번호를 다시 확인해 주세요'); end if;
  update draw_logs set status = 'expired' where source = 'guest' and status = 'pending' and phone = ph and coupon_expires_at is not null and coupon_expires_at < now();
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', l.id, 'code', l.confirm_code, 'rank', l.rank, 'prize', l.prize_label, 'status', l.status, 'drawn_at', l.drawn_at, 'expires_at', l.coupon_expires_at,
      'branch', b.name, 'branch_id', l.branch_id, 'done_at', l.done_at) order by l.drawn_at desc)
    from draw_logs l join manual_branches b on b.id = l.branch_id
    where l.source = 'guest' and l.phone = ph and (l.status = 'pending' or (l.status in ('given', 'substituted', 'expired') and l.drawn_at > now() - interval '30 days'))), '[]'::jsonb));
end $$;

-- 매장폰: 쿠폰 찾기 (코드 4글자 또는 전화번호 뒤 4자리 이상). 우리 매장 쿠폰만, 안 쓴 것 + 만료
create or replace function draw_coupon_lookup(p_branch uuid, p_staff uuid, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare q text; d text;
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  perform draw__expire(p_branch);
  q := upper(trim(coalesce(p_q, ''))); d := draw__digits(q);
  if length(q) < 4 then return draw__err('코드 4글자 또는 번호 뒤 4자리 이상 넣어 주세요'); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'code', confirm_code, 'rank', rank, 'prize', prize_label, 'status', status, 'method', method, 'drawn_at', drawn_at,
      'expires_at', coupon_expires_at, 'phone_masked', draw__mask(phone)) order by drawn_at desc)
    from (select * from draw_logs where branch_id = p_branch and source = 'guest' and status in ('pending', 'expired')
          and (confirm_code = q or (length(d) >= 4 and phone is not null and phone like '%' || d)) order by drawn_at desc limit 20) x), '[]'::jsonb));
end $$;

-- 매장폰: 오늘 발급된 쿠폰 + 안 쓴 것 (최근 24시간)
create or replace function draw_guest_pending(p_branch uuid, p_staff uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  perform draw__expire(p_branch);
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'code', confirm_code, 'rank', rank, 'prize', prize_label, 'status', status, 'method', method, 'drawn_at', drawn_at,
      'expires_at', coupon_expires_at, 'phone_masked', draw__mask(phone)) order by drawn_at desc)
    from draw_logs where branch_id = p_branch and source = 'guest' and status in ('pending', 'expired') and drawn_at > now() - interval '24 hours'), '[]'::jsonb));
end $$;

revoke all on function draw__pick_core(uuid, int, text, uuid, text, text, text, text, boolean), draw__digits(text), draw__mask(text) from public, anon, authenticated;
grant execute on function draw_guest_pick(uuid, text, text, int, text, boolean, boolean), draw_guest_status(uuid, text, text), draw_coupon_find(text), draw_coupon_lookup(uuid, uuid, text), draw_guest_pending(uuid, uuid) to anon, authenticated;
