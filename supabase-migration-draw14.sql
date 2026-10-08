-- 리뷰 뽑기판 v2-13: 배분 변경(500원·1,000원·한 번 더 순으로 많이) + "한 번 더"는 한 번만 — draw13.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)

-- 1) 배분: 1·3·16·40·70·50·100·90·150 (합 520), 지금 판 닫고 바로 적용
update draw_config set counts = '{1,3,16,40,70,50,100,90,150}', updated_at = now() where id = 1;
update draw_boards set closed_at = now(), closed_by = 'owner' where closed_at is null;

-- 2) "한 번 더"로 다시 뽑을 때는 "한 번 더"가 또 나오지 않음
create or replace function draw__pick_core(p_branch uuid, p_cell int, p_method text, p_staff uuid, p_source text, p_device text, p_ip text, p_phone text, p_marketing boolean, p_review text, p_redraw uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k int; m text; c int; code text; exp timestamptz; rv text; nr int; kinds text[]; kd text; rd draw_logs;
begin
  m := case when p_method in ('board', 'capsule', 'claw', 'hunt', 'quiz', 'wheel') then p_method else 'board' end;
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
  -- '한 번 더'로 다시 뽑는 중이면 '한 번 더'는 또 안 나오게: 그 등수를 빼고 다시 고른다
  if p_redraw is not null and kd = 'redraw' then
    total := total - b.remaining[r];
    if total > 0 then
      pick := floor(random() * total)::int + 1; acc := 0;
      for k in 1..nr loop
        if coalesce(kinds[k], 'instant') = 'redraw' then continue; end if;
        acc := acc + b.remaining[k];
        if pick <= acc then r := k; exit; end if;
      end loop;
      kd := coalesce(kinds[r], 'instant');
    end if;
  end if;

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
