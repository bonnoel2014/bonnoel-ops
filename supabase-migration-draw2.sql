-- 리뷰 뽑기판 v2-1: 캡슐 뽑기(게임 모드) — supabase-migration-draw.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 바뀌는 것: 뽑기 기록에 "어떤 방법으로 뽑았는지"(method) 칸 추가,
--            draw_pick 에 p_method 추가 + 칸 번호 없이(p_cell null) 부르면 서버가 안 뽑힌 칸을 하나 골라 줌 (캡슐 뽑기용)
-- 확률·판·집계·취소는 그대로.

alter table draw_logs add column if not exists method text not null default 'board';   -- board(뽑기판) / capsule(캡슐 뽑기)

drop function if exists draw_pick(uuid, uuid, int);

create or replace function draw_pick(p_branch uuid, p_staff uuid, p_cell int, p_method text default 'board') returns jsonb
language plpgsql security definer set search_path = public as $$
declare b draw_boards; lb jsonb; total int; pick int; acc int; r int; lg draw_logs; k text; m text; c int;
begin
  if not draw__staff_ok(p_staff, p_branch) then return draw__err('매장폰 계정으로 다시 로그인해 주세요'); end if;
  m := case when p_method in ('board', 'capsule') then p_method else 'board' end;
  if p_cell is not null and (p_cell < 0 or p_cell > 519) then return draw__err('칸 번호가 이상해요'); end if;
  select labels into lb from draw_prizes where branch_id = p_branch;
  for k in select unnest(array['1','2','3','4','5']) loop
    if coalesce(trim(lb ->> k), '') = '' then return draw__err('상품표를 먼저 채워 주세요 (뽑기 상품표 메뉴)'); end if;
  end loop;

  b := draw__open_board(p_branch);
  select * into b from draw_boards where id = b.id for update;
  if b.closed_at is not null then b := draw__open_board(p_branch); select * into b from draw_boards where id = b.id for update; end if;

  c := p_cell;
  if c is null then
    -- 캡슐 뽑기: 손님이 칸을 안 고르니 서버가 안 뽑힌 칸 하나를 골라 준다 (판 자국은 똑같이 남음)
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
  insert into draw_logs (board_id, branch_id, cell, rank, prize_label, staff_id, method)
  values (b.id, p_branch, c, r, lb ->> r::text, p_staff, m) returning * into lg;

  if total - 1 <= 0 then update draw_boards set closed_at = now(), closed_by = 'auto' where id = b.id; end if;

  return jsonb_build_object('ok', true, 'log_id', lg.id, 'rank', r, 'prize', lg.prize_label, 'cell', c, 'method', m);
end $$;

grant execute on function draw_pick(uuid, uuid, int, text) to anon, authenticated;
