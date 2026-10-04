-- 리뷰 뽑기판 v2-2: 손님 폰 QR 뽑기 — draw.sql, draw2.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 손님이 POP의 QR을 찍고 자기 폰에서 뽑은 뒤 결과 화면(4글자 확인 코드)을 직원에게 보여 준다.
-- 막는 장치: 손님 기기(device)마다 하루 1번 · 같은 인터넷(IP)에서 하루 6번 · 30분 안에 지급 확인 안 되면 만료(알은 판으로 복귀).

alter table draw_logs add column if not exists source text not null default 'staff';      -- staff(매장폰) / guest(손님 폰 QR)
alter table draw_logs add column if not exists device_id text;
alter table draw_logs add column if not exists ip text;
alter table draw_logs add column if not exists confirm_code text;
alter table draw_logs drop constraint if exists draw_logs_status_check;
alter table draw_logs add constraint draw_logs_status_check check (status in ('pending', 'given', 'substituted', 'cancelled', 'expired'));
create index if not exists draw_logs_guest_day on draw_logs(device_id, drawn_at) where source = 'guest';

-- 만료: 손님 폰으로 뽑고 30분 안에 지급 확인이 안 된 건 → expired, 판이 열려 있으면 알 복귀
create or replace function draw__expire(p_branch uuid) returns void
language plpgsql security definer set search_path = public as $$
declare lg record; b draw_boards;
begin
  for lg in select * from draw_logs where branch_id = p_branch and source = 'guest' and status = 'pending' and drawn_at < now() - interval '30 minutes' for update skip locked loop
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

-- 공통 뽑기 (매장폰·손님 폰 둘 다 여기로)
create or replace function draw__pick_core(p_branch uuid, p_cell int, p_method text, p_staff uuid, p_source text, p_device text, p_ip text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k text; m text; c int; code text;
begin
  m := case when p_method in ('board', 'capsule') then p_method else 'board' end;
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
  end if;
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id, method, source, device_id, ip, confirm_code)
  values (b.id, p_branch, c, r, lb ->> r::text, p_staff, m, p_source, p_device, p_ip, code) returning * into lg;

  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'cell', c, 'method', m, 'code', code, 'drawn_at', lg.drawn_at);
end $$;

-- 매장폰 뽑기 (서명은 draw2와 같음)
create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int, p_method text default 'board') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  return draw__pick_core(p_branch, p_cell, p_method, p_staff, 'staff', null, null);
end $$;

-- 손님 폰 뽑기: 기기(device)마다 하루 1번, 같은 IP 하루 6번
create or replace function draw_guest_pick(p_branch uuid, p_device text, p_method text default 'capsule', p_cell int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ip text; n int; today_from timestamptz;
begin
  if coalesce(p_device, '') = '' or length(p_device) > 80 then return draw__err('브라우저를 새로고침한 뒤 다시 해 주세요'); end if;
  if not exists (select 1 from manual_branches where id = p_branch) then return draw__err('매장을 찾을 수 없어요. QR을 다시 찍어 주세요'); end if;
  begin v_ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); exception when others then v_ip := null; end;
  today_from := (now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul';
  select count(*) into n from draw_logs where source = 'guest' and device_id = p_device and drawn_at >= today_from and status <> 'cancelled';
  if n >= 1 then return draw__err('오늘은 이미 뽑았어요 😊 내일 또 와 주세요'); end if;
  if coalesce(v_ip, '') <> '' then
    select count(*) into n from draw_logs l where l.source = 'guest' and l.ip = v_ip and l.drawn_at >= today_from and l.status <> 'cancelled';
    if n >= 6 then return draw__err('같은 인터넷에서 너무 많이 뽑았어요. 직원에게 말씀해 주세요'); end if;
  end if;
  return draw__pick_core(p_branch, p_cell, p_method, null, 'guest', p_device, nullif(v_ip, ''));
end $$;

-- 손님 폰에서 "지급됐는지" 확인 (자기 기기 것만)
create or replace function draw_guest_status(p_log uuid, p_device text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('ok', true, 'status', status, 'rank', rank, 'prize', prize_label, 'code', confirm_code, 'drawn_at', drawn_at, 'substitute', substitute)
                   from draw_logs where id = p_log and device_id = p_device and source = 'guest'), draw__err('기록을 못 찾았어요'))
$$;

-- 매장폰: 손님 폰으로 뽑은 것 목록 (최근 3시간, 지급 안 된 것 + 만료된 것)
create or replace function draw_guest_pending(p_branch uuid, p_staff uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  perform draw__expire(p_branch);
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'code', confirm_code, 'rank', rank, 'prize', prize_label, 'status', status, 'method', method, 'drawn_at', drawn_at) order by drawn_at desc)
    from draw_logs where branch_id = p_branch and source = 'guest' and status in ('pending', 'expired') and drawn_at > now() - interval '3 hours'), '[]'::jsonb));
end $$;

-- 지급 완료: 만료된 손님 뽑기도 직원이 확인하면 지급으로 (알은 이미 돌아갔으니 판은 안 건드림)
create or replace function draw_done(p_log uuid, p_status text, p_substitute text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg draw_logs;
begin
  if p_status not in ('given', 'substituted') then return draw__err('상태가 이상해요'); end if;
  if p_status = 'substituted' and coalesce(trim(p_substitute), '') = '' then return draw__err('뭘 드렸는지 적어 주세요'); end if;
  select * into lg from draw_logs where id = p_log for update;
  if lg.id is null then return draw__err('뽑기 기록을 못 찾았어요'); end if;
  if lg.status = 'cancelled' then return draw__err('이미 취소된 뽑기예요'); end if;
  update draw_logs set status = p_status, substitute = case when p_status = 'substituted' then trim(p_substitute) else null end, done_at = now() where id = p_log;
  return jsonb_build_object('ok', true);
end $$;

-- 판 칸 목록도 만료 처리 먼저
create or replace function draw_board_cells(p_branch uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards;
begin
  perform draw__expire(p_branch);
  b := draw__open_board(p_branch);
  return jsonb_build_object('ok', true, 'board_id', b.id, 'taken', to_jsonb(b.taken), 'total', 520);
end $$;

revoke all on function draw__expire(uuid), draw__pick_core(uuid, int, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function draw_guest_pick(uuid, text, text, int), draw_guest_status(uuid, text), draw_guest_pending(uuid, uuid) to anon, authenticated;
