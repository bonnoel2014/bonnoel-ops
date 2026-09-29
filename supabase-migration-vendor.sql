-- =========================================================
-- 본노엘 운영 앱: 거래처 납품 · 월 명세서 (우디집·파랜드·앤드밀·카멜)
-- 성수 매니저가 날짜별 납품 개수를 넣고 → 사장님이 월초에 지난달 명세서를 만들어 카톡으로 보내고 → 입금 확인
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 1. 거래처 (명세서를 받는 곳)
create table if not exists ops_vendors (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,              -- 우디집, 파랜드, 앤드밀, 카멜
  pay_note text,                          -- 명세서에 쓰는 결제 방식 (예: 현금 · 계산서 미발행)
  contact text,                           -- 담당자·연락처 (명세서엔 안 나옴, 사장님 참고용)
  memo text,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 2. 납품처 (앤드밀처럼 한 거래처에 매장이 여러 곳이면 여러 줄. 한 곳이면 '기본' 한 줄)
create table if not exists ops_vendor_sites (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references ops_vendors(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 3. 품목·단가 (거래처마다 따로. 단가는 1개 값)
create table if not exists ops_vendor_items (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references ops_vendors(id) on delete cascade,
  name text not null,
  price numeric not null default 0,
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 4. 날짜별 납품 개수 (날짜 + 납품처 + 품목 = 한 줄)
create table if not exists ops_vendor_deliveries (
  id uuid primary key default gen_random_uuid(),
  deliver_on date not null,
  site_id uuid not null references ops_vendor_sites(id) on delete cascade,
  item_id uuid not null references ops_vendor_items(id) on delete cascade,
  qty numeric not null default 0,
  staff_id uuid references manual_staff(id) on delete set null,   -- 마지막으로 넣은 사람
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ops_vendor_deliveries_one_idx on ops_vendor_deliveries (deliver_on, site_id, item_id);
create index if not exists ops_vendor_deliveries_date_idx on ops_vendor_deliveries (deliver_on);

-- 5. 더하고 빼는 금액 (택배비 +, 택시비 −, 반품·할인 −, 기타). amount는 부호 포함 (빼는 건 음수)
create table if not exists ops_vendor_extras (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references ops_vendors(id) on delete cascade,
  site_id uuid references ops_vendor_sites(id) on delete set null,
  on_date date not null,
  kind text not null default 'etc',       -- delivery(택배비) / taxi(택시비) / return(반품) / discount(할인) / etc(기타)
  amount numeric not null default 0,
  memo text,
  staff_id uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ops_vendor_extras_date_idx on ops_vendor_extras (on_date);

-- 6. 월 명세서 (보냄을 누르면 그때 금액을 그대로 고정해서 저장 → 나중에 단가를 바꿔도 안 변함)
create table if not exists ops_vendor_statements (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references ops_vendors(id) on delete cascade,
  ym text not null,                       -- '2026-10'
  status text not null default 'sent',    -- sent(보냄) / paid(입금 완료)
  snapshot jsonb not null default '{}'::jsonb,
  total numeric not null default 0,       -- 이번에 받을 돈 (전달 미입금 포함)
  sent_at timestamptz,
  paid_on date,
  paid_amount numeric,
  memo text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ops_vendor_statements_one_idx on ops_vendor_statements (vendor_id, ym);

-- 권한 (다른 운영 표와 같은 방식)
alter table ops_vendors enable row level security;
alter table ops_vendor_sites enable row level security;
alter table ops_vendor_items enable row level security;
alter table ops_vendor_deliveries enable row level security;
alter table ops_vendor_extras enable row level security;
alter table ops_vendor_statements enable row level security;
drop policy if exists "anon full access" on ops_vendors;
drop policy if exists "anon full access" on ops_vendor_sites;
drop policy if exists "anon full access" on ops_vendor_items;
drop policy if exists "anon full access" on ops_vendor_deliveries;
drop policy if exists "anon full access" on ops_vendor_extras;
drop policy if exists "anon full access" on ops_vendor_statements;
create policy "anon full access" on ops_vendors for all using (true) with check (true);
create policy "anon full access" on ops_vendor_sites for all using (true) with check (true);
create policy "anon full access" on ops_vendor_items for all using (true) with check (true);
create policy "anon full access" on ops_vendor_deliveries for all using (true) with check (true);
create policy "anon full access" on ops_vendor_extras for all using (true) with check (true);
create policy "anon full access" on ops_vendor_statements for all using (true) with check (true);

-- 설정 표 (다른 모듈에서 이미 만들었으면 건너뜀)
create table if not exists ops_settings (
  key text primary key,
  value jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

-- =========================================================
-- 처음 거래처·단가 (2026년 9월 엑셀 기준). 이미 있으면 건너뜀
-- =========================================================
do $$
declare v uuid;
begin
  -- 우디집: 쁘띠 현금가 1,400 (판매가 1,750의 80%)
  if not exists (select 1 from ops_vendors where name = '우디집') then
    insert into ops_vendors (name, pay_note, sort_order) values ('우디집', '현금 (계산서 미발행)', 1) returning id into v;
    insert into ops_vendor_sites (vendor_id, name, sort_order) values (v, '기본', 1);
    insert into ops_vendor_items (vendor_id, name, price, sort_order) values (v, '쁘띠', 1400, 1);
  end if;
  -- 파랜드: 쁘띠 납품 현금가 1,750
  if not exists (select 1 from ops_vendors where name = '파랜드') then
    insert into ops_vendors (name, pay_note, sort_order) values ('파랜드', '현금 (계산서 미발행)', 2) returning id into v;
    insert into ops_vendor_sites (vendor_id, name, sort_order) values (v, '기본', 1);
    insert into ops_vendor_items (vendor_id, name, price, sort_order) values (v, '쁘띠', 1750, 1);
  end if;
  -- 앤드밀: 성수·종각·청담. 쁘띠·브리오 = 판매가 ÷ 1.1, 하드바게트 2,200
  if not exists (select 1 from ops_vendors where name = '앤드밀') then
    insert into ops_vendors (name, pay_note, sort_order) values ('앤드밀', '세금계산서 발행 (부가세 포함)', 3) returning id into v;
    insert into ops_vendor_sites (vendor_id, name, sort_order) values (v, '성수', 1), (v, '종각', 2), (v, '청담', 3);
    insert into ops_vendor_items (vendor_id, name, price, sort_order) values (v, '쁘띠', 1591, 1), (v, '브리오', 4545, 2), (v, '하드바게트', 2200, 3);
  end if;
  -- 카멜 (성수): 앙버터 4,840
  if not exists (select 1 from ops_vendors where name = '카멜') then
    insert into ops_vendors (name, pay_note, sort_order) values ('카멜', '세금계산서 발행 (부가세 포함)', 4) returning id into v;
    insert into ops_vendor_sites (vendor_id, name, sort_order) values (v, '성수', 1);
    insert into ops_vendor_items (vendor_id, name, price, sort_order) values (v, '앙버터', 4840, 1);
  end if;
end $$;

-- 명세서 머리글(공급자)·입금 계좌 — 앱의 [거래처 설정]에서 고칠 수 있어요
insert into ops_settings (key, value) values ('vendor_stmt', '{"supplier":"본노엘","ceo":"손성필","phone":"010-3815-1470","biz_no":"","bank":"","footer":"위 금액으로 입금해 주세요. 감사합니다."}'::jsonb)
on conflict (key) do nothing;

-- =========================================================
-- 7. 납품 영수증 사진 (9/30 추가) — 거래처·납품처별 그날 영수증. 사진은 법인카드와 같은 receipts 저장소의 vendor/ 폴더
-- =========================================================
create table if not exists ops_vendor_receipts (
  id uuid primary key default gen_random_uuid(),
  deliver_on date not null,
  vendor_id uuid not null references ops_vendors(id) on delete cascade,
  site_id uuid references ops_vendor_sites(id) on delete set null,
  photo_path text not null,
  staff_id uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ops_vendor_receipts_date_idx on ops_vendor_receipts (deliver_on);
alter table ops_vendor_receipts enable row level security;
drop policy if exists "anon full access" on ops_vendor_receipts;
create policy "anon full access" on ops_vendor_receipts for all using (true) with check (true);

-- receipts 저장소 (법인카드 SQL을 이미 했으면 그대로 있음. 없을 때만 만듦)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "receipts read" on storage.objects;
create policy "receipts read" on storage.objects for select using (bucket_id = 'receipts');
drop policy if exists "receipts insert" on storage.objects;
create policy "receipts insert" on storage.objects for insert with check (bucket_id = 'receipts');
drop policy if exists "receipts delete" on storage.objects;
create policy "receipts delete" on storage.objects for delete using (bucket_id = 'receipts');

-- 본노엘 사업자번호 (영수증에서 확인) — 비어 있을 때만 채움
update ops_settings set value = jsonb_set(value, '{biz_no}', '"354-85-01989"')
where key = 'vendor_stmt' and coalesce(value->>'biz_no', '') = '';
