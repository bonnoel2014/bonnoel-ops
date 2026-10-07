-- 리뷰 뽑기판 v2-5: 손님 폰 뽑기도 "바로 수령" + "소금이를 찾아라" 게임 — draw5.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 바뀌는 것: 손님 폰 당첨의 받는 기한이 3주 → 오늘(한국 시간 자정)까지. 뽑는 방법(method)에 'hunt'(소금이 찾기) 허용. 번호·동의 수집은 그대로.

create or replace function draw__pick_core(p_branch uuid, p_cell int, p_method text, p_staff uuid, p_source text, p_device text, p_ip text, p_phone text, p_marketing boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k text; m text; c int; code text; exp timestamptz;
begin
  m := case when p_method in ('board', 'capsule', 'claw', 'hunt') then p_method else 'board' end;
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
    -- 바로 수령: 오늘(한국 시간) 자정까지
    if p_phone is not null then exp := ((now() at time zone 'Asia/Seoul')::date + 1)::timestamp at time zone 'Asia/Seoul'; end if;
  end if;
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id, method, source, device_id, ip, confirm_code, phone, consent_at, marketing_ok, coupon_expires_at)
  values (b.id, p_branch, c, r, lb ->> r::text, p_staff, m, p_source, p_device, p_ip, code, p_phone, case when p_phone is not null then now() end, coalesce(p_marketing, false), exp) returning * into lg;

  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'cell', c, 'method', m, 'code', code, 'drawn_at', lg.drawn_at,
    'expires_at', exp, 'phone_masked', draw__mask(p_phone), 'branch', (select name from manual_branches where id = p_branch));
end $$;
