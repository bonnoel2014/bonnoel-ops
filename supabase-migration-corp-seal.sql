-- =========================================================
-- 본노엘 운영 앱: 법인 서류 — 직인(사용인감) 보관
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- 먼저 필요한 것: supabase-migration-corp.sql
--
-- · 직인 이미지는 잠긴 corp_settings 표 안에만 보관 (앱에서 직접 못 읽음)
-- · 사장님 코드가 맞아야만 꺼내거나 바꿀 수 있음
-- · 서류를 만들 때 "직인 찍기"를 체크한 것만 찍힘
-- =========================================================

alter table corp_settings add column if not exists seal text;   -- 배경을 지운 작은 PNG (data URL)

-- 한 번에 다 불러오기: 직인 그림은 빼고 "있는지"만 알려줌 (그림은 corp_seal_get 으로 따로)
create or replace function corp_get(p_code text, p_date date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_date, (now() at time zone 'Asia/Seoul')::date);
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  return jsonb_build_object('ok', true,
    'settings', (select to_jsonb(s) - 'id' - 'seal' || jsonb_build_object('has_seal', s.seal is not null) from corp_settings s where id = 1),
    'holdings', corp__holdings(d),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.event_date desc, e.created_at desc) from corp_share_events e), '[]'::jsonb),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'title', f.title, 'file_name', f.file_name, 'mime', f.mime, 'size', f.size, 'issued_on', f.issued_on, 'memo', f.memo, 'uploaded_at', f.uploaded_at) order by f.uploaded_at desc) from corp_files f), '[]'::jsonb),
    'links', coalesce((select jsonb_agg(to_jsonb(l) order by l.created_at desc) from corp_share_links l where l.created_at > now() - interval '60 days'), '[]'::jsonb),
    'issues', coalesce((select jsonb_agg(to_jsonb(i) - 'data' order by i.created_at desc) from (select * from corp_issues order by created_at desc limit 300) i), '[]'::jsonb));
end $$;

create or replace function corp_seal_get(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  return jsonb_build_object('ok', true, 'seal', (select seal from corp_settings where id = 1));
end $$;

-- p_seal 이 비면 직인 지우기
create or replace function corp_seal_set(p_code text, p_seal text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not corp__ok(p_code) then return corp__err(); end if;
  if p_seal is not null and (p_seal not like 'data:image/%' or length(p_seal) > 700000) then
    return jsonb_build_object('ok', false, 'error', '직인 이미지가 너무 크거나 형식이 달라요');
  end if;
  update corp_settings set seal = p_seal, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;

select '직인 준비 완료 — 앱의 법인 서류 → 회사 정보에서 도장 사진을 올리세요' as 결과;
