-- =========================================================
-- 본노엘 운영 앱: 매출·손익 (일일 보고서)
-- 사장님이 하루 한 번 4매장 매출(매장·배민·쿠팡이츠)을 넣으면 → 그날 손익계산서가 자동으로 나옴
-- 재료비 = 매출 × 원가율, 인건비 = 매장별 하루 고정값(그날만 고칠 수 있음), 배달 수수료 = 채널별 %, 고정비 = 월 고정비 ÷ 그 달 일수
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run (한 번만, 여러 번 실행해도 안전)
-- =========================================================

-- 날짜별·매장별 매출 (날짜 + 매장 = 한 줄)
create table if not exists ops_daily_sales (
  id uuid primary key default gen_random_uuid(),
  sale_on date not null,
  branch_id uuid not null references manual_branches(id) on delete cascade,
  store_amt numeric not null default 0,     -- 매장 매출 (POS)
  baemin_amt numeric not null default 0,    -- 배민 매출
  coupang_amt numeric not null default 0,   -- 쿠팡이츠 매출
  labor numeric,                            -- 그날 인건비 (비우면 설정의 하루 고정값)
  memo text,                                -- 날씨·특이사항
  staff_id uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ops_daily_sales_one_idx on ops_daily_sales (sale_on, branch_id);
create index if not exists ops_daily_sales_date_idx on ops_daily_sales (sale_on);

-- 권한 (다른 운영 표와 같은 방식)
alter table ops_daily_sales enable row level security;
drop policy if exists "anon full access" on ops_daily_sales;
create policy "anon full access" on ops_daily_sales for all using (true) with check (true);

-- 설정 표 (다른 모듈에서 이미 만들었으면 건너뜀)
create table if not exists ops_settings (
  key text primary key,
  value jsonb not null default '{}',
  updated_at timestamptz not null default now()
);

-- 원가율·수수료·매장별 인건비·고정비 — 앱의 [손익 설정]에서 고칠 수 있어요
insert into ops_settings (key, value) values ('pnl_cfg', '{"cost_rate":32,"fee_baemin":25,"fee_coupang":25,"br":{}}'::jsonb)
on conflict (key) do nothing;

-- =========================================================
-- 월 정산 (2차): 매장별 한 달 손익에서 사장님이 실제 금액으로 고친 값
-- 비워 둔 칸(null)은 앱이 자동 값(일일 보고서 합계·급여 초안·설정)을 씀
-- =========================================================
create table if not exists ops_month_close (
  id uuid primary key default gen_random_uuid(),
  ym text not null,                         -- '2026-10'
  branch_id uuid not null references manual_branches(id) on delete cascade,
  material numeric,                         -- 실제 재료비
  labor numeric,                            -- 실제 인건비
  fee numeric,                              -- 실제 배달 수수료
  fixed numeric,                            -- 실제 고정비
  other numeric,                            -- 기타 비용 (수리비·소모품 등)
  other_memo text,
  memo text,
  staff_id uuid references manual_staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists ops_month_close_one_idx on ops_month_close (ym, branch_id);
alter table ops_month_close enable row level security;
drop policy if exists "anon full access" on ops_month_close;
create policy "anon full access" on ops_month_close for all using (true) with check (true);
