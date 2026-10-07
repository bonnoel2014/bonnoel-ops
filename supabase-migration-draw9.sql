-- 리뷰 뽑기판 v2-8: 손님 폰에서 바로 "상품 받았어요" 확인 — draw8.sql 뒤에 SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 바쁜 카운터용: 직원이 빵을 건네면서 손님 폰 화면의 버튼을 한 번 누르면 지급 완료. 매장폰 검색은 보조.

alter table draw_logs add column if not exists done_by text;   -- 'staff'(매장폰) / 'guest'(손님 폰 버튼)

create or replace function draw_guest_done(p_log uuid, p_device text, p_phone text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg draw_logs;
begin
  select * into lg from draw_logs where id = p_log and source = 'guest' and (device_id = p_device or (phone is not null and phone = draw__digits(p_phone))) for update;
  if lg.id is null then return draw__err('기록을 못 찾았어요'); end if;
  if lg.status in ('given', 'substituted') then return jsonb_build_object('ok', true, 'status', lg.status, 'done_at', lg.done_at); end if;
  if lg.status = 'cancelled' then return draw__err('취소된 뽑기예요'); end if;
  if lg.status = 'expired' then return draw__err('받는 기한(당일)이 지났어요. 직원에게 말씀해 주세요'); end if;
  update draw_logs set status = 'given', done_at = now(), done_by = 'guest' where id = lg.id;
  return jsonb_build_object('ok', true, 'status', 'given', 'done_at', now());
end $$;

-- 매장폰에서 지급 완료한 건 'staff'로 표시
create or replace function draw_done(p_log uuid, p_status text, p_substitute text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare lg draw_logs;
begin
  if p_status not in ('given', 'substituted') then return draw__err('상태가 이상해요'); end if;
  if p_status = 'substituted' and coalesce(trim(p_substitute), '') = '' then return draw__err('뭘 드렸는지 적어 주세요'); end if;
  select * into lg from draw_logs where id = p_log for update;
  if lg.id is null then return draw__err('뽑기 기록을 못 찾았어요'); end if;
  if lg.status = 'cancelled' then return draw__err('이미 취소된 뽑기예요'); end if;
  update draw_logs set status = p_status, substitute = case when p_status = 'substituted' then trim(p_substitute) else null end, done_at = now(), done_by = 'staff' where id = p_log;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function draw_guest_done(uuid, text, text) to anon, authenticated;
