-- =========================================================
-- 본노엘 보안 1단계: 비밀번호 확인을 서버로 옮기고 "출입증(토큰)" 만들기
-- 사용법: Supabase → SQL Editor → New query → 이 파일 전체 붙여넣기 → Run
--         (글자를 선택한 채로 Run 하면 선택한 부분만 실행되니, 아무것도 선택하지 않고 Run)
--         여러 번 실행해도 안전해요.
--
-- 이 단계는 "준비"만 해요. 지금 쓰는 앱은 그대로 돌아가요(아무것도 안 잠금).
--   · staff_secrets  : 직원 비밀번호를 암호(bcrypt)로만 보관. 앱에서는 아무도 못 읽음
--   · staff_sessions : 로그인하면 받는 출입증. 앱에서는 아무도 못 읽음
--   · staff_login 등 : 이름+비밀번호를 서버에서 확인하고 출입증을 내주는 함수
--   · staff__role 등 : 2단계 잠금에서 "이 요청이 누구인지" 확인할 때 쓰는 함수
-- 새 앱을 올린 다음 보안-2-잠금.sql 을 실행하면 그때 표가 잠겨요.
-- =========================================================

create extension if not exists pgcrypto with schema extensions;

-- 1. 비밀번호 보관함 (암호로만)
create table if not exists staff_secrets (
  staff_id uuid primary key references manual_staff(id) on delete cascade,
  pin_hash text,                              -- bcrypt. 원래 숫자는 저장 안 함
  fails int not null default 0,               -- 연속으로 틀린 횟수
  locked_until timestamptz,                   -- 5번 틀리면 잠시 잠금
  updated_at timestamptz not null default now()
);
alter table staff_secrets enable row level security;
revoke all on staff_secrets from anon, authenticated;

-- 2. 출입증 (토큰 원본은 저장 안 하고 지문(sha256)만 저장)
create table if not exists staff_sessions (
  token_hash text primary key,
  staff_id uuid not null references manual_staff(id) on delete cascade,
  branch_id uuid,                             -- 로그인할 때 고른 매장 (사장님은 매장을 골라 들어옴)
  app text,                                   -- ops / hiring
  created_at timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  expires_at timestamptz not null
);
create index if not exists staff_sessions_staff_idx on staff_sessions (staff_id);
alter table staff_sessions enable row level security;
revoke all on staff_sessions from anon, authenticated;

-- 3. 지금 manual_staff.pin 에 있는 비밀번호를 암호로 옮겨 담기 (이미 옮긴 사람은 건드리지 않음)
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'manual_staff' and column_name = 'pin') then
    execute $q$
      insert into staff_secrets (staff_id, pin_hash)
      select id, extensions.crypt(pin, extensions.gen_salt('bf', 8)) from manual_staff where pin ~ '^\d{4}$'
      on conflict (staff_id) do nothing
    $q$;
  end if;
end $$;

-- ===== 내부 도우미 =====
create or replace function staff__hash(p_token text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

-- 이 요청에 붙어 온 출입증 (헤더 x-staff-token)
create or replace function staff__token() returns text
language sql stable as $$
  select nullif(nullif(current_setting('request.headers', true), '')::json->>'x-staff-token', '');
$$;

-- 출입증 주인 (퇴사·만료면 없음). 역할은 매번 manual_staff 에서 새로 읽음 → 역할을 바꾸면 바로 반영
create or replace function staff__ctx() returns table (staff_id uuid, role text, branch_id uuid)
language sql stable security definer set search_path = public, extensions as $$
  select m.id, coalesce(m.role, 'staff'), coalesce(s.branch_id, m.branch_id)
  from staff_sessions s join manual_staff m on m.id = s.staff_id
  where s.token_hash = staff__hash(staff__token())
    and s.expires_at > now() and m.active is not false
  limit 1;
$$;

-- 사장님 앱(owner.bonnoel.com)에 로그인한 사장님 계정이면 true
create or replace function staff__owner_auth() returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('public.owner_users') is null then return false; end if;
  return exists (select 1 from owner_users where user_id = auth.uid());
end $$;

-- 지금 요청한 사람의 역할: owner / manager / kiosk / staff / null(로그인 안 함)
create or replace function staff__role() returns text
language sql stable security definer set search_path = public as $$
  select case when staff__owner_auth() then 'owner' else (select role from staff__ctx()) end;
$$;
create or replace function staff__is_owner() returns boolean
language sql stable security definer set search_path = public as $$ select coalesce(staff__role() = 'owner', false); $$;
-- 매장폰(kiosk)은 사장님 결정(9/27)대로 매니저와 같은 권한
create or replace function staff__is_manager() returns boolean
language sql stable security definer set search_path = public as $$ select coalesce(staff__role() in ('owner', 'manager', 'kiosk'), false); $$;
create or replace function staff__is_staff() returns boolean
language sql stable security definer set search_path = public as $$ select staff__role() is not null; $$;
create or replace function staff__id() returns uuid
language sql stable security definer set search_path = public as $$ select staff_id from staff__ctx(); $$;

-- 출입증 새로 만들기 (원본 토큰은 이때 한 번만 앱에 돌려줌)
create or replace function staff__issue(p_staff uuid, p_branch uuid, p_app text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_tok text := encode(extensions.gen_random_bytes(24), 'hex'); m manual_staff%rowtype;
begin
  select * into m from manual_staff where id = p_staff;
  insert into staff_sessions (token_hash, staff_id, branch_id, app, expires_at)
  values (staff__hash(v_tok), p_staff, case when m.role = 'owner' or m.branch_id is null then p_branch else m.branch_id end,
          left(coalesce(p_app, 'ops'), 20),
          -- 매장폰 출퇴근·서명 화면에서 잠깐 쓰는 출입증은 12시간, 로그인은 180일(앱 열 때마다 연장)
          now() + case when p_app in ('clock', 'sign') then interval '12 hours' else interval '180 days' end);
  delete from staff_sessions where expires_at < now();
  return jsonb_build_object('ok', true, 'token', v_tok, 'staff_id', m.id, 'name', m.name, 'role', coalesce(m.role, 'staff'),
    'branch_id', case when m.role = 'owner' or m.branch_id is null then p_branch else m.branch_id end);
end $$;

-- 비밀번호 확인 (틀린 횟수 세기: 5번마다 잠금 5분 → 10분 → 20분 … 최대 하루)
create or replace function staff__check(p_staff uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r staff_secrets%rowtype;
begin
  select * into r from staff_secrets where staff_id = p_staff for update;
  if not found or r.pin_hash is null then return jsonb_build_object('ok', false, 'need_new', true); end if;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', '비밀번호를 여러 번 틀려서 잠겼어요. ' || greatest(1, ceil(extract(epoch from r.locked_until - now()) / 60))::int || '분 뒤에 다시 해 보거나 매니저·사장님께 초기화를 부탁하세요', 'locked', true);
  end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' or extensions.crypt(p_pin, r.pin_hash) <> r.pin_hash then
    update staff_secrets set fails = fails + 1,
      locked_until = case when (fails + 1) % 5 = 0 then now() + least(interval '5 minutes' * power(2, (fails + 1) / 5 - 1), interval '24 hours') else locked_until end
    where staff_id = p_staff;
    return jsonb_build_object('ok', false, 'error', '비밀번호가 틀려요');
  end if;
  update staff_secrets set fails = 0, locked_until = null where staff_id = p_staff;
  return jsonb_build_object('ok', true);
end $$;

create or replace function staff__save_pin(p_staff uuid, p_pin text) returns void
language sql security definer set search_path = public, extensions as $$
  insert into staff_secrets (staff_id, pin_hash, fails, locked_until, updated_at)
  values (p_staff, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)), 0, null, now())
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, fails = 0, locked_until = null, updated_at = now();
$$;

-- ===== 앱에서 부르는 함수 =====

-- 비밀번호를 이미 정한 사람 목록 (로그인 화면이 "처음이시네요"를 보여줄지 정할 때). 숫자는 안 나옴
create or replace function staff_pin_list() returns table (staff_id uuid, has_pin boolean)
language sql stable security definer set search_path = public as $$
  select m.id, exists (select 1 from staff_secrets s where s.staff_id = m.id and s.pin_hash is not null)
  from manual_staff m;
$$;

-- 로그인: 맞으면 출입증, 처음이면 need_new, 틀리면 error
create or replace function staff_login(p_staff uuid, p_pin text, p_branch uuid default null, p_app text default 'ops') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m manual_staff%rowtype; c jsonb;
begin
  select * into m from manual_staff where id = p_staff;
  if not found or m.active is false then return jsonb_build_object('ok', false, 'error', '퇴사 처리된 이름이라 들어갈 수 없어요'); end if;
  c := staff__check(p_staff, p_pin);
  if not (c->>'ok')::boolean then return c; end if;
  return staff__issue(p_staff, p_branch, p_app);
end $$;

-- 처음 들어온 사람이 비밀번호 정하기 (이미 정한 사람은 안 됨)
create or replace function staff_first_pin(p_staff uuid, p_pin text, p_branch uuid default null, p_app text default 'ops') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare m manual_staff%rowtype;
begin
  select * into m from manual_staff where id = p_staff;
  if not found or m.active is false then return jsonb_build_object('ok', false, 'error', '퇴사 처리된 이름이라 들어갈 수 없어요'); end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then return jsonb_build_object('ok', false, 'error', '숫자 4자리로 넣어 주세요'); end if;
  if exists (select 1 from staff_secrets where staff_id = p_staff and pin_hash is not null) then
    return jsonb_build_object('ok', false, 'error', '이미 비밀번호가 있어요. 비밀번호를 넣어 들어가 주세요');
  end if;
  perform staff__save_pin(p_staff, p_pin);
  return staff__issue(p_staff, p_branch, p_app);
end $$;

-- 내 비밀번호 바꾸기 (지금 비밀번호를 알아야 함). 이 출입증 말고 다른 곳의 로그인은 끊김
create or replace function staff_change_pin(p_staff uuid, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c jsonb;
begin
  if coalesce(p_new, '') !~ '^\d{4}$' then return jsonb_build_object('ok', false, 'error', '숫자 4자리로 넣어 주세요'); end if;
  c := staff__check(p_staff, p_old);
  if not (c->>'ok')::boolean then
    if (c->>'need_new')::boolean then return jsonb_build_object('ok', false, 'error', '아직 비밀번호가 없어요'); end if;
    if c->>'error' = '비밀번호가 틀려요' then return jsonb_build_object('ok', false, 'error', '지금 비밀번호가 달라요'); end if;
    return c;
  end if;
  perform staff__save_pin(p_staff, p_new);
  delete from staff_sessions where staff_id = p_staff and token_hash is distinct from staff__hash(staff__token());
  return jsonb_build_object('ok', true);
end $$;

-- 1225로 초기화 (매니저·매장폰·사장님). 사장님 비밀번호는 사장님만
create or replace function staff_reset_pin(p_staff uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_role text;
begin
  if not staff__is_manager() then return jsonb_build_object('ok', false, 'error', '매니저·사장님만 초기화할 수 있어요'); end if;
  select role into v_role from manual_staff where id = p_staff;
  if not found then return jsonb_build_object('ok', false, 'error', '직원을 찾을 수 없어요'); end if;
  if v_role in ('owner', 'kiosk') and not staff__is_owner() then return jsonb_build_object('ok', false, 'error', '사장님만 초기화할 수 있어요'); end if;
  perform staff__save_pin(p_staff, '1225');
  delete from staff_sessions where staff_id = p_staff;
  return jsonb_build_object('ok', true);
end $$;

-- 비밀번호 직접 정해 주기 (사장님만: 매장폰 비밀번호 바꾸기)
create or replace function staff_set_pin(p_staff uuid, p_pin text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not staff__is_owner() then return jsonb_build_object('ok', false, 'error', '사장님만 바꿀 수 있어요'); end if;
  if coalesce(p_pin, '') !~ '^\d{4}$' then return jsonb_build_object('ok', false, 'error', '숫자 4자리로 넣어 주세요'); end if;
  if not exists (select 1 from manual_staff where id = p_staff) then return jsonb_build_object('ok', false, 'error', '직원을 찾을 수 없어요'); end if;
  perform staff__save_pin(p_staff, p_pin);
  delete from staff_sessions where staff_id = p_staff;
  return jsonb_build_object('ok', true);
end $$;

-- 지금 출입증이 유효한지 + 기한 연장 (앱을 열 때마다 부름 → 매일 쓰는 폰은 계속 로그인 유지)
create or replace function staff_whoami() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c record; m manual_staff%rowtype;
begin
  select * into c from staff__ctx();
  if c.staff_id is null then return jsonb_build_object('ok', false); end if;
  update staff_sessions set last_seen = now(), expires_at = now() + interval '180 days'
  where token_hash = staff__hash(staff__token()) and last_seen < now() - interval '1 hour' and coalesce(app, '') not in ('clock', 'sign');
  select * into m from manual_staff where id = c.staff_id;
  return jsonb_build_object('ok', true, 'staff_id', c.staff_id, 'name', m.name, 'role', c.role, 'branch_id', c.branch_id);
end $$;

-- 로그아웃 (이 출입증만 지움)
create or replace function staff_logout() returns jsonb
language sql security definer set search_path = public, extensions as $$
  delete from staff_sessions where token_hash = staff__hash(staff__token());
  select jsonb_build_object('ok', true);
$$;

-- 퇴사 처리하거나 역할이 바뀌면 그 사람 출입증을 모두 끊기
create or replace function staff__on_staff_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (new.active is false and old.active is not false) or new.role is distinct from old.role then
    delete from staff_sessions where staff_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists staff_sessions_cut on manual_staff;
create trigger staff_sessions_cut after update on manual_staff for each row execute function staff__on_staff_change();

-- ===== 권한: 도우미(staff__*)는 앱에서 직접 못 부르고, 앱용 함수만 열어 둠 =====
revoke all on function staff__hash(text), staff__ctx(), staff__issue(uuid, uuid, text), staff__check(uuid, text), staff__save_pin(uuid, text), staff__on_staff_change() from public, anon, authenticated;
-- 정책(2단계)에서 쓰는 확인 함수는 누구나 부를 수 있어야 함 (결과는 true/false 뿐)
grant execute on function staff__token(), staff__owner_auth(), staff__role(), staff__is_owner(), staff__is_manager(), staff__is_staff(), staff__id() to anon, authenticated;
revoke all on function staff_pin_list(), staff_login(uuid, text, uuid, text), staff_first_pin(uuid, text, uuid, text), staff_change_pin(uuid, text, text), staff_reset_pin(uuid), staff_set_pin(uuid, text), staff_whoami(), staff_logout() from public;
grant execute on function staff_pin_list(), staff_login(uuid, text, uuid, text), staff_first_pin(uuid, text, uuid, text), staff_change_pin(uuid, text, text), staff_reset_pin(uuid), staff_set_pin(uuid, text), staff_whoami(), staff_logout() to anon, authenticated;

-- 확인: 비밀번호를 옮겨 담은 사람 수 (숫자만 보여요)
select (select count(*) from staff_secrets where pin_hash is not null) as 비밀번호_옮긴_사람,
       (select count(*) from manual_staff where active is not false) as 재직_중_인원;
