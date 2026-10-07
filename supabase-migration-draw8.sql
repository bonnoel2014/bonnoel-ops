-- 리뷰 뽑기판 v2-7: 리뷰 쓸 곳 고르기(네이버·구글·카카오맵·티맵) — draw7.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 매장별 리뷰 링크(사장님 앱에서 입력)와, 손님이 어디에 리뷰를 썼는지(review_source) 기록.

alter table draw_prizes add column if not exists review_links jsonb not null default '{}'::jsonb;   -- {"naver":"https://naver.me/...","google":"...","kakao":"...","tmap":"..."}
alter table draw_logs add column if not exists review_source text;                                   -- naver / google / kakao / tmap

-- 상품표 읽기에 링크도 같이
create or replace function draw_prizes_get(p_branch uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true,
    'labels', coalesce((select labels from draw_prizes where branch_id = p_branch), '{}'::jsonb),
    'links', coalesce((select review_links from draw_prizes where branch_id = p_branch), '{}'::jsonb))
$$;

-- 공통 뽑기 (리뷰 출처 추가)
drop function if exists draw__pick_core(uuid, int, text, uuid, text, text, text, text, boolean);
create or replace function draw__pick_core(p_branch uuid, p_cell int, p_method text, p_staff uuid, p_source text, p_device text, p_ip text, p_phone text, p_marketing boolean, p_review text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k text; m text; c int; code text; exp timestamptz; rv text;
begin
  m := case when p_method in ('board', 'capsule', 'claw', 'hunt') then p_method else 'board' end;
  rv := case when p_review in ('naver', 'google', 'kakao', 'tmap') then p_review else null end;
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
    if p_phone is not null then exp := ((now() at time zone 'Asia/Seoul')::date + 1)::timestamp at time zone 'Asia/Seoul'; end if;
  end if;
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id, method, source, device_id, ip, confirm_code, phone, consent_at, marketing_ok, coupon_expires_at, review_source)
  values (b.id, p_branch, c, r, lb ->> r::text, p_staff, m, p_source, p_device, p_ip, code, p_phone, case when p_phone is not null then now() end, coalesce(p_marketing, false), exp, rv) returning * into lg;

  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'cell', c, 'method', m, 'code', code, 'drawn_at', lg.drawn_at,
    'expires_at', exp, 'phone_masked', draw__mask(p_phone), 'branch', (select name from manual_branches where id = p_branch));
end $$;

create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int, p_method text default 'board') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  return draw__pick_core(p_branch, p_cell, p_method, p_staff, 'staff', null, null, null, false, null);
end $$;

drop function if exists draw_guest_pick(uuid, text, text, int, text, boolean, boolean);
create or replace function draw_guest_pick(p_branch uuid, p_device text, p_method text, p_cell int, p_phone text, p_consent boolean, p_marketing boolean default false, p_review text default null) returns jsonb
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
  return draw__pick_core(p_branch, p_cell, p_method, null, 'guest', p_device, nullif(v_ip, ''), ph, p_marketing, p_review);
end $$;

revoke all on function draw__pick_core(uuid, int, text, uuid, text, text, text, text, boolean, text) from public, anon, authenticated;
grant execute on function draw_guest_pick(uuid, text, text, int, text, boolean, boolean, text), draw_prizes_get(uuid) to anon, authenticated;

-- 씨앗: 사장님이 알려 준 링크 (왕십리점 티맵, 2026-10-07). 나머지는 사장님 앱 → 리뷰 뽑기 → [리뷰 링크]에서 입력
update draw_prizes set review_links = coalesce(review_links, '{}'::jsonb) || '{"tmap":"https://tmap.life/f7fa15d6"}'::jsonb, updated_at = now()
where branch_id = (select id from manual_branches where name = '왕십리점') and coalesce(review_links ->> 'tmap', '') = '';
update draw_prizes set review_links = coalesce(review_links, '{}'::jsonb) || '{"google":"https://share.google/O0IIiYCcBSthbTYB5"}'::jsonb, updated_at = now()
where branch_id = (select id from manual_branches where name = '왕십리점');
update draw_prizes set review_links = coalesce(review_links, '{}'::jsonb) || '{"kakao":"https://place.map.kakao.com/197855372"}'::jsonb, updated_at = now()
where branch_id = (select id from manual_branches where name = '왕십리점') and coalesce(review_links ->> 'kakao', '') = '';
update draw_prizes set review_links = coalesce(review_links, '{}'::jsonb) || '{"naver":"https://naver.me/xHmNKuVZ"}'::jsonb, updated_at = now()
where branch_id = (select id from manual_branches where name = '왕십리점') and coalesce(review_links ->> 'naver', '') = '';
