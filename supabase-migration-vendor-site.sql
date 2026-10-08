-- =========================================================
-- 거래처 명세서를 납품처별로 따로 (앤드밀 성수·종각·청담 각각 명세서·보냄·입금)
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (여러 번 실행해도 안전)
-- =========================================================
alter table ops_vendor_statements add column if not exists site_id uuid references ops_vendor_sites(id) on delete cascade;
-- 예전 "거래처+월 = 한 장" 규칙을 "거래처+월+납품처 = 한 장"으로 바꿈
drop index if exists ops_vendor_statements_one_idx;
create unique index if not exists ops_vendor_statements_one_site_idx
  on ops_vendor_statements (vendor_id, ym, coalesce(site_id, '00000000-0000-0000-0000-000000000000'::uuid));
