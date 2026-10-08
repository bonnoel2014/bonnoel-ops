-- 고객의 소리 ("의견 주세요") v1 — SQL Editor에서 한 번 실행 (여러 번 실행해도 안전)
-- 손님: 매장 QR(ops.bonnoel.com/?v=<매장 id>) → 로그인 없이 voice_submit 함수로 쓰기만 가능 (남의 의견은 누구도 못 읽음)
-- 사장님: 사장님 앱(owner.bonnoel.com, owner__is)만 읽기·처리. 매장폰·매니저는 못 봄 (사장님 결정 2026-10-08)
-- 기획: 기획/고객의소리/PRD_전체.md

create table if not exists voice_feedback (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references manual_branches(id) on delete cascade,
  kind text not null check (kind in ('complaint', 'praise', 'idea', 'improve', 'etc')),   -- 불편 · 칭찬 · 아이디어 · 바라는 점 · 기타
  body text not null check (length(body) between 5 and 1000),
  visit text,                          -- 방문 시간대: morning·lunch·afternoon·evening·other
  name text,                           -- (선택)
  phone text,                          -- (선택) 숫자만 01012345678
  want_reply boolean not null default false,
  consent_at timestamptz,              -- 이름·번호를 남길 때 개인정보 수집·이용 동의 시각
  device_id text,
  ip text,
  status text not null default 'new' check (status in ('new', 'seen', 'replied', 'done', 'hidden')),
  owner_memo text,
  reply_text text,                     -- 사장님이 보낸 답장 문구 (기록용, 발송은 사장님이 직접)
  replied_at timestamptz,
  done_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists voice_feedback_created on voice_feedback(created_at desc);
create index if not exists voice_feedback_status on voice_feedback(status);
create index if not exists voice_feedback_device on voice_feedback(device_id, created_at);

alter table voice_feedback enable row level security;
drop policy if exists voice_owner_all on voice_feedback;
create policy voice_owner_all on voice_feedback for all to authenticated using (owner__is()) with check (owner__is());
revoke all on voice_feedback from anon;

-- 손님 의견 보내기 (로그인 없음)
create or replace function voice_submit(p_branch uuid, p_device text, p_kind text, p_body text, p_visit text, p_name text, p_phone text, p_want_reply boolean, p_consent boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ip text; n int; today_from timestamptz; ph text; nm text; bd text;
begin
  if coalesce(p_device, '') = '' or length(p_device) > 80 then return jsonb_build_object('ok', false, 'error', '브라우저를 새로고침한 뒤 다시 해 주세요'); end if;
  if not exists (select 1 from manual_branches where id = p_branch) then return jsonb_build_object('ok', false, 'error', '매장을 찾을 수 없어요. QR을 다시 찍어 주세요'); end if;
  if p_kind not in ('complaint', 'praise', 'idea', 'improve', 'etc') then return jsonb_build_object('ok', false, 'error', '어떤 의견인지 하나 골라 주세요'); end if;
  bd := trim(coalesce(p_body, ''));
  if length(bd) < 5 then return jsonb_build_object('ok', false, 'error', '조금만 더 자세히 알려 주세요 (5자 이상)'); end if;
  if length(bd) > 1000 then return jsonb_build_object('ok', false, 'error', '1,000자까지 쓸 수 있어요'); end if;
  nm := nullif(left(trim(coalesce(p_name, '')), 30), '');
  ph := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '');
  if ph is not null and ph !~ '^01[0-9]{8,9}$' then return jsonb_build_object('ok', false, 'error', '휴대폰 번호를 다시 확인해 주세요 (예: 010-1234-5678)'); end if;
  if coalesce(p_want_reply, false) and ph is null then return jsonb_build_object('ok', false, 'error', '답장을 받으려면 휴대폰 번호를 넣어 주세요'); end if;
  if (ph is not null or nm is not null) and not coalesce(p_consent, false) then return jsonb_build_object('ok', false, 'error', '이름·번호를 남기려면 개인정보 수집·이용에 동의해 주세요 (익명이면 비워 두세요)'); end if;
  begin v_ip := trim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)); exception when others then v_ip := null; end;
  today_from := (now() at time zone 'Asia/Seoul')::date::timestamp at time zone 'Asia/Seoul';
  select count(*) into n from voice_feedback where device_id = p_device and created_at >= today_from;
  if n >= 3 then return jsonb_build_object('ok', false, 'error', '오늘은 이 폰으로 의견을 충분히 받았어요. 고마워요! 내일 또 들려주세요'); end if;
  if coalesce(v_ip, '') <> '' then
    select count(*) into n from voice_feedback where ip = v_ip and created_at >= today_from;
    if n >= 10 then return jsonb_build_object('ok', false, 'error', '같은 인터넷에서 의견이 너무 많이 왔어요. 매장 직원에게 말씀해 주세요'); end if;
  end if;
  insert into voice_feedback(branch_id, kind, body, visit, name, phone, want_reply, consent_at, device_id, ip)
  values (p_branch, p_kind, bd,
          case when p_visit in ('morning', 'lunch', 'afternoon', 'evening', 'other') then p_visit else null end,
          nm, ph, coalesce(p_want_reply, false) and ph is not null,
          case when ph is not null or nm is not null then now() else null end,
          p_device, nullif(v_ip, ''));
  return jsonb_build_object('ok', true);
end $$;

revoke all on function voice_submit(uuid, text, text, text, text, text, text, boolean, boolean) from public;
grant execute on function voice_submit(uuid, text, text, text, text, text, text, boolean, boolean) to anon, authenticated;
