-- =========================================================
-- 본노엘 운영 앱: 법인 서류 (재직·경력증명서, 주주명부, 법인 서류함, 발급 대장·진위 확인)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- 먼저 필요한 것: supabase-migration-prepay.sql (사장님 코드를 같이 씀)
--
-- 잠금 방식 (선결제와 같음):
--   · corp_ 표는 앱에서 직접 읽기·쓰기 불가 (RLS 켜고 허용 규칙 없음)
--   · 모든 일은 아래 함수로만, 함수가 "사장님 코드(선결제와 같은 6자리)"를 서버에서 확인
--   · 누구나 부를 수 있는 건 두 개뿐: 진위 확인(corp_verify), 기한 링크 열기(corp_share_open)
--   · 직원의 증명서 "신청"만 다른 운영 표처럼 열려 있음(ops_cert_requests) — 비밀 정보 없음
-- =========================================================

create extension if not exists pgcrypto with schema extensions;

-- 1. 회사 정보·설정 (한 줄뿐)
create table if not exists corp_settings (
  id int primary key default 1 check (id = 1),
  company jsonb not null default '{}',          -- name, reg_no(법인등록번호), biz_no(사업자등록번호), address, ceo, phone
  total_shares bigint,                          -- 발행주식 총수
  par_value int,                                -- 1주의 금액(원)
  updated_at timestamptz not null default now()
);
insert into corp_settings (id, company) values (1, jsonb_build_object(
  'name', '주식회사 본노엘', 'reg_no', '110111-7698488',
  'address', '서울시 동대문구 전농로75-18, 1층(답십리동)', 'ceo', '손성필'))
on conflict (id) do nothing;

-- 2. 주주 (사람) + 주식 변동 기록 (지우지 않고 쌓음 → 어느 날짜 기준으로든 주주명부를 다시 만들 수 있음)
create table if not exists corp_shareholders (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  birth text,                                   -- 생년월일 (주민번호는 저장 안 함)
  address text,
  relation text,                                -- 메모 (예: 대표, 배우자)
  share_kind text not null default '보통주',
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create table if not exists corp_share_events (
  id uuid primary key default gen_random_uuid(),
  shareholder_id uuid not null references corp_shareholders(id) on delete cascade,
  event_date date not null,
  delta bigint not null,                        -- 늘어나면 +, 줄어들면 −
  reason text not null default '기타',          -- 설립 / 증자 / 양수 / 양도 / 증여 / 상속 / 기타
  memo text,
  created_at timestamptz not null default now()
);
create index if not exists corp_share_events_holder on corp_share_events(shareholder_id, event_date);

-- 3. 법인 서류함 (파일은 DB 안에 잠가서 보관 — 저장소 버킷을 안 써서 목록이 새지 않음)
create table if not exists corp_files (
  id uuid primary key default gen_random_uuid(),
  kind text not null,                           -- 사업자등록증 / 법인등기사항증명서 / 정관 / 법인인감증명서 / 통장사본 / 주주명부 / 기타
  title text not null,
  file_name text not null,
  mime text not null,
  size int not null,
  data bytea not null,
  issued_on date,                               -- 서류 발급일 (등본·인감은 보통 3개월 안 것만 받아줌)
  memo text,
  uploaded_at timestamptz not null default now()
);

-- 4. 기한 링크 (거래처·은행·세무사에게 보내는 주소, 기한 지나면 안 열림)
create table if not exists corp_share_links (
  token text primary key,
  file_id uuid not null references corp_files(id) on delete cascade,
  memo text,                                    -- 누구에게 보냈는지
  expires_at timestamptz not null,
  revoked boolean not null default false,
  open_count int not null default 0,
  last_opened_at timestamptz,
  created_at timestamptz not null default now()
);

-- 5. 발급 대장 (재직·경력증명서, 주주명부를 만들 때마다 한 줄)
create table if not exists corp_issues (
  id uuid primary key default gen_random_uuid(),
  issue_no text not null unique,                -- 예: BN-2026-0001
  verify_key text not null,                     -- QR 안에 들어가는 확인 글자 (번호만으로 남의 서류를 조회 못 하게)
  doc_type text not null,                       -- 재직증명서 / 경력증명서 / 주주명부
  subject_name text,                            -- 대상자 (주주명부는 '기준일 2026-09-26')
  staff_id uuid references manual_staff(id) on delete set null,
  purpose text,
  recipient text,                               -- 제출처
  data jsonb not null default '{}',             -- 발급 당시 내용 (나중에 다시 봐도 같게)
  pdf_sha256 text,
  revoked boolean not null default false,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

alter table corp_settings enable row level security;
alter table corp_shareholders enable row level security;
alter table corp_share_events enable row level security;
alter table corp_files enable row level security;
alter table corp_share_links enable row level security;
alter table corp_issues enable row level security;
revoke all on corp_settings, corp_shareholders, corp_share_events, corp_files, corp_share_links, corp_issues from anon, authenticated;

-- 6. 직원 증명서 신청 (운영 앱의 다른 표처럼 열려 있음)
create table if not exists ops_cert_requests (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references manual_staff(id) on delete cascade,
  kind text not null default 'employment',      -- employment(재직) / career(경력)
  purpose text,
  recipient text,
  email text,
  status text not null default 'requested',     -- requested / issued / rejected / canceled
  issue_no text,
  pdf_path text,                                -- 저장소 documents 안의 PDF
  note text,                                    -- 반려 사유 등
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists ops_cert_requests_staff on ops_cert_requests(staff_id, created_at);
alter table ops_cert_requests enable row level security;
drop policy if exists "anon full access" on ops_cert_requests;
create policy "anon full access" on ops_cert_requests for all using (true) with check (true);

-- ===== 내부 도우미 =====
create or replace function corp__ok(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  -- 틀리면 prepay__auth 가 null 을 돌려줌 → coalesce 없이 비교하면 null 이 되어 "not null" 검사를 그냥 통과해 버림
  return coalesce(prepay__auth(null, p_code), '') = 'owner';
end $$;

create or replace function corp__err() returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', false, 'error', '사장님 코드가 틀려요 (선결제 사장님 코드와 같은 6자리)')
$$;

create or replace function corp__holdings(p_date date) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(x order by x.sort_order, x.first_date nulls last, x.name), '[]'::jsonb) from (
    select h.id, h.name, h.birth, h.address, h.relation, h.share_kind, h.sort_order,
      coalesce(sum(e.delta) filter (where e.event_date <= p_date), 0) as shares,
      min(e.event_date) filter (where e.delta > 0 and e.event_date <= p_date) as first_date,
      max(e.event_date) filter (where e.event_date <= p_date) as last_date
    from corp_shareholders h left join corp_share_events e on e.shareholder_id = h.id
    group by h.id
  ) x
$$;

-- ===== 누구나 (비밀 없음) =====
create or replace function corp_status() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object('ready', (select owner_code_hash is not null from prepay_settings where id = 1))
$$;

-- ===== 사장님 코드가 맞아야 하는 것 =====
create or replace function corp_login(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 한 번에 다 불러오기 (파일 내용은 빼고 목록만)
create or replace function corp_get(p_code text, p_date date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_date, (now() at time zone 'Asia/Seoul')::date);
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  return jsonb_build_object('ok', true,
    'settings', (select to_jsonb(s) - 'id' from corp_settings s where id = 1),
    'holdings', corp__holdings(d),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.event_date desc, e.created_at desc) from corp_share_events e), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'title', f.title, 'file_name', f.file_name, 'mime', f.mime, 'size', f.size, 'issued_on', f.issued_on, 'memo', f.memo, 'uploaded_at', f.uploaded_at) order by f.uploaded_at desc) from corp_files f), '[]'::jsonb),
    'links', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from corp_share_links l where l.created_at > now() - interval '60 days'), '[]'::jsonb),
    'issues', coalesce((select jsonb_agg(to_jsonb(i) - 'data' order by i.created_at desc) from (select * from corp_issues order by created_at desc limit 300) i), '[]'::jsonb));
end $$;

create or replace function corp_save_settings(p_code text, p_company jsonb, p_total_shares bigint, p_par_value int) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  update corp_settings set company = coalesce(p_company, '{}'::jsonb), total_shares = p_total_shares, par_value = p_par_value, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;

-- 주주 추가·고치기 (p_holder.id 가 있으면 고치기)
create or replace function corp_save_holder(p_code text, p_holder jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  if coalesce(trim(p_holder->>'name'), '') = '' then return jsonb_build_object('ok', false, 'error', '이름을 넣어 주세요'); end if;
  if coalesce(p_holder->>'id', '') <> '' then
    update corp_shareholders set name = trim(p_holder->>'name'), birth = nullif(p_holder->>'birth', ''), address = nullif(p_holder->>'address', ''),
      relation = nullif(p_holder->>'relation', ''), share_kind = coalesce(nullif(p_holder->>'share_kind', ''), '보통주'),
      sort_order = coalesce((p_holder->>'sort_order')::int, sort_order)
    where id = (p_holder->>'id')::uuid returning id into v_id;
  else
    insert into corp_shareholders (name, birth, address, relation, share_kind, sort_order)
    values (trim(p_holder->>'name'), nullif(p_holder->>'birth', ''), nullif(p_holder->>'address', ''), nullif(p_holder->>'relation', ''),
      coalesce(nullif(p_holder->>'share_kind', ''), '보통주'), coalesce((p_holder->>'sort_order')::int, (select coalesce(max(sort_order), 0) + 1 from corp_shareholders)))
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function corp_delete_holder(p_code text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  delete from corp_shareholders where id = p_id;   -- 변동 기록도 같이 지워짐
  return jsonb_build_object('ok', true);
end $$;

create or replace function corp_add_event(p_code text, p_event jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_delta bigint := (p_event->>'delta')::bigint; v_holder uuid := (p_event->>'shareholder_id')::uuid; v_date date := (p_event->>'event_date')::date; v_after bigint;
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  if v_delta is null or v_delta = 0 then return jsonb_build_object('ok', false, 'error', '주식 수를 넣어 주세요'); end if;
  if v_date is null then return jsonb_build_object('ok', false, 'error', '날짜를 넣어 주세요'); end if;
  select coalesce(sum(delta), 0) + v_delta into v_after from corp_share_events where shareholder_id = v_holder and event_date <= v_date;
  if v_after < 0 then return jsonb_build_object('ok', false, 'error', '그 날짜에 가진 주식보다 많이 줄일 수 없어요'); end if;
  insert into corp_share_events (shareholder_id, event_date, delta, reason, memo)
  values (v_holder, v_date, v_delta, coalesce(nullif(p_event->>'reason', ''), '기타'), nullif(p_event->>'memo', ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function corp_delete_event(p_code text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  delete from corp_share_events where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 서류함: 올리기 (내용은 base64 글자로 받음, 8MB까지)
create or replace function corp_file_put(p_code text, p_meta jsonb, p_b64 text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_data bytea; v_id uuid;
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  v_data := decode(p_b64, 'base64');
  if length(v_data) > 8 * 1024 * 1024 then return jsonb_build_object('ok', false, 'error', '파일이 너무 커요 (8MB까지)'); end if;
  insert into corp_files (kind, title, file_name, mime, size, data, issued_on, memo)
  values (coalesce(nullif(p_meta->>'kind', ''), '기타'), coalesce(nullif(p_meta->>'title', ''), p_meta->>'file_name', '서류'),
    coalesce(nullif(p_meta->>'file_name', ''), 'file'), coalesce(nullif(p_meta->>'mime', ''), 'application/octet-stream'),
    length(v_data), v_data, nullif(p_meta->>'issued_on', '')::date, nullif(p_meta->>'memo', ''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

create or replace function corp_file_get(p_code text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f corp_files;
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  select * into f from corp_files where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', '파일이 없어요'); end if;
  return jsonb_build_object('ok', true, 'file_name', f.file_name, 'mime', f.mime, 'b64', encode(f.data, 'base64'));
end $$;

create or replace function corp_file_delete(p_code text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  delete from corp_files where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- 기한 링크 만들기·끊기
create or replace function corp_share_create(p_code text, p_file uuid, p_days int, p_memo text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text := replace(replace(replace(encode(gen_random_bytes(18), 'base64'), '+', '-'), '/', '_'), '=', '');
        v_exp timestamptz := now() + make_interval(days => greatest(1, least(coalesce(p_days, 3), 30)));
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  if not exists (select 1 from corp_files where id = p_file) then return jsonb_build_object('ok', false, 'error', '파일이 없어요'); end if;
  insert into corp_share_links (token, file_id, memo, expires_at) values (v_token, p_file, nullif(p_memo, ''), v_exp);
  return jsonb_build_object('ok', true, 'token', v_token, 'expires_at', v_exp);
end $$;

create or replace function corp_share_revoke(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  update corp_share_links set revoked = true where token = p_token;
  return jsonb_build_object('ok', true);
end $$;

-- 발급 대장에 올리기 → 발급번호·확인 글자 받기 (PDF에 찍음)
create or replace function corp_issue(p_code text, p_doc jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_year text := to_char(now() at time zone 'Asia/Seoul', 'YYYY'); v_n int; v_no text; v_key text; v_id uuid;
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  if coalesce(p_doc->>'doc_type', '') not in ('재직증명서', '경력증명서', '주주명부') then return jsonb_build_object('ok', false, 'error', '서류 종류가 이상해요'); end if;
  perform 1 from corp_settings where id = 1 for update;   -- 번호가 겹치지 않게 한 줄씩
  select coalesce(max(substring(issue_no from 9)::int), 0) + 1 into v_n from corp_issues where issue_no like 'BN-' || v_year || '-%';
  v_no := 'BN-' || v_year || '-' || lpad(v_n::text, 4, '0');
  v_key := upper(substring(encode(gen_random_bytes(6), 'hex') from 1 for 8));
  insert into corp_issues (issue_no, verify_key, doc_type, subject_name, staff_id, purpose, recipient, data)
  values (v_no, v_key, p_doc->>'doc_type', nullif(p_doc->>'subject_name', ''), nullif(p_doc->>'staff_id', '')::uuid,
    nullif(p_doc->>'purpose', ''), nullif(p_doc->>'recipient', ''), coalesce(p_doc->'data', '{}'::jsonb))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'issue_no', v_no, 'verify_key', v_key, 'company', (select company from corp_settings where id = 1));
end $$;

create or replace function corp_issue_set_sha(p_code text, p_issue_no text, p_sha text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  update corp_issues set pdf_sha256 = p_sha where issue_no = p_issue_no;
  return jsonb_build_object('ok', true);
end $$;

create or replace function corp_issue_revoke(p_code text, p_issue_no text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  update corp_issues set revoked = true, revoked_at = now() where issue_no = p_issue_no;
  return jsonb_build_object('ok', true);
end $$;

-- ===== 누구나: 진위 확인 (QR) =====
-- 번호 + 확인 글자가 둘 다 맞아야 보여줌. 이름은 가운데를 가림 (손*필)
create or replace function corp_verify(p_no text, p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i corp_issues; v_name text;
begin
  select * into i from corp_issues where issue_no = upper(trim(p_no)) and verify_key = upper(trim(p_key));
  if not found then return jsonb_build_object('ok', false); end if;
  v_name := coalesce(i.subject_name, '');
  if i.doc_type <> '주주명부' and char_length(v_name) >= 2 then
    v_name := left(v_name, 1) || repeat('*', greatest(char_length(v_name) - 2, 1)) || case when char_length(v_name) > 2 then right(v_name, 1) else '' end;
  end if;
  return jsonb_build_object('ok', true, 'issue_no', i.issue_no, 'doc_type', i.doc_type, 'subject', v_name, 'purpose', i.purpose,
    'issued_at', i.created_at, 'revoked', i.revoked, 'sha', i.pdf_sha256, 'company', (select company->>'name' from corp_settings where id = 1));
end $$;

-- ===== 누구나: 기한 링크 열기 =====
create or replace function corp_share_open(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l corp_share_links; f corp_files;
begin
  select * into l from corp_share_links where token = p_token for update;
  if not found or l.revoked then return jsonb_build_object('ok', false, 'error', '없거나 끊긴 링크예요'); end if;
  if l.expires_at < now() then return jsonb_build_object('ok', false, 'error', '기한이 지난 링크예요 (' || to_char(l.expires_at at time zone 'Asia/Seoul', 'YYYY-MM-DD HH24:MI') || '까지)'); end if;
  select * into f from corp_files where id = l.file_id;
  if not found then return jsonb_build_object('ok', false, 'error', '파일이 지워졌어요'); end if;
  update corp_share_links set open_count = open_count + 1, last_opened_at = now() where token = p_token;
  return jsonb_build_object('ok', true, 'title', f.title, 'file_name', f.file_name, 'mime', f.mime, 'b64', encode(f.data, 'base64'),
    'expires_at', l.expires_at, 'company', (select company->>'name' from corp_settings where id = 1));
end $$;

-- 내부 도우미는 밖에서 못 부르게
revoke execute on function corp__ok(text) from public, anon, authenticated;
revoke execute on function corp__holdings(date) from public, anon, authenticated;
