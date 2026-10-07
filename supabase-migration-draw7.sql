-- 리뷰 뽑기판 v2-6: 사장님이 기록 지우기 (테스트 흔적·개인정보 삭제 요청) — draw6.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 사장님 앱(로그인한 사장님)에서만 부를 수 있음. 지운 뽑기의 알은 판이 열려 있으면 판으로 돌아감.

create or replace function draw_owner_delete(p_phone text default null, p_log uuid default null, p_device_prefix text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg record; b draw_boards; n int := 0; ph text;
begin
  if not owner__is() then return draw__err('사장님만 할 수 있어요'); end if;
  ph := nullif(draw__digits(p_phone), '');
  if ph is null and p_log is null and coalesce(p_device_prefix, '') = '' then return draw__err('무엇을 지울지 정해 주세요'); end if;
  for lg in select * from draw_logs
            where (p_log is not null and id = p_log)
               or (ph is not null and phone = ph)
               or (coalesce(p_device_prefix, '') <> '' and device_id like p_device_prefix || '%')
            for update loop
    select * into b from draw_boards where id = lg.board_id for update;
    if b.id is not null and b.closed_at is null and lg.status <> 'cancelled' and not lg.returned then
      b.remaining[lg.rank] := b.remaining[lg.rank] + 1;
      update draw_boards set remaining = b.remaining, taken = array_remove(taken, lg.cell) where id = b.id;
    end if;
    delete from draw_logs where id = lg.id;
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;
revoke all on function draw_owner_delete(text, uuid, text) from public, anon;
grant execute on function draw_owner_delete(text, uuid, text) to authenticated;
