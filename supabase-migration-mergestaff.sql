-- =========================================================
-- 본노엘 운영 앱: 중복 직원 정리 (한 번만 실행하는 일회성 스크립트)
-- 원인: "근무 패턴 → 한꺼번에 붙여넣기"에 성 빠진 이름(예: "예승")을 넣으면
--       앱이 그걸 새 사람으로 자동 등록해서 진짜 사람("손예승")과 중복이 생김.
-- 하는 일: 아래 표에 적힌 대로 "중복 이름"의 모든 기록(근무표·출퇴근·급여·보건증·서류 등)을
--          "진짜 이름" 쪽으로 옮기고, 중복 줄 자체는 지우지 않고 비활성(퇴사자 칸)으로만 내림.
-- 사용법: Supabase 대시보드 -> SQL Editor -> New query -> 전체 붙여넣기 -> Run.
--        실행 결과 메시지(Notice/Message 탭)에 어떤 이름이 합쳐졌는지, 못 찾은 게 있는지 나옵니다.
--        이미 합친 이름을 다시 실행해도 안전합니다(두 번째부터는 "건너뜀"으로 나옴).
-- =========================================================

do $$
declare
  r record;
  old_id uuid;
  new_id uuid;
  old_cnt int;
  new_cnt int;
begin
  for r in select * from (values
    ('예승', null::text, '손예승', null::text),
    ('진주', null::text, '장진주', null::text),
    ('박민서S', '성수점', '박민서', '성수점'),
    ('박민서D', '답십리점', '박민서', '답십리점'),
    ('매니저', null::text, '최하늘', null::text),
    ('민경', null::text, '박민경', null::text)
  ) as t(old_name, old_branch, new_name, new_branch)
  loop
    select count(*) into old_cnt from manual_staff s left join manual_branches b on b.id = s.branch_id
      where s.name = r.old_name and s.active = true and (r.old_branch is null or b.name = r.old_branch);
    select count(*) into new_cnt from manual_staff s left join manual_branches b on b.id = s.branch_id
      where s.name = r.new_name and s.active = true and (r.new_branch is null or b.name = r.new_branch);

    if old_cnt = 0 then
      raise notice '건너뜀: "%"는 이미 없어요 (예전에 정리됐거나 이름이 달라요)', r.old_name;
      continue;
    end if;
    if old_cnt > 1 then
      raise notice '건너뜀: "%"가 %명이라 어느 쪽인지 몰라요 (사장님이 직접 확인해 주세요)', r.old_name, old_cnt;
      continue;
    end if;
    if new_cnt <> 1 then
      raise notice '건너뜀: 합칠 대상 "%" (%)를 정확히 한 명 못 찾음 (%명 찾음)', r.new_name, coalesce(r.new_branch,'전체'), new_cnt;
      continue;
    end if;

    select s.id into old_id from manual_staff s left join manual_branches b on b.id = s.branch_id
      where s.name = r.old_name and s.active = true and (r.old_branch is null or b.name = r.old_branch);
    select s.id into new_id from manual_staff s left join manual_branches b on b.id = s.branch_id
      where s.name = r.new_name and s.active = true and (r.new_branch is null or b.name = r.new_branch);

    if old_id = new_id then
      raise notice '건너뜀: "%"와 "%"가 이미 같은 사람이에요', r.old_name, r.new_name;
      continue;
    end if;

    -- 같은 날짜·요청에 둘 다 기록이 있어 충돌할 수 있는 표는, 겹치는 줄만 "진짜" 쪽을 남기고 "중복" 쪽 줄을 지움
    delete from ops_pay_profiles where staff_id = old_id and exists (select 1 from ops_pay_profiles where staff_id = new_id);
    delete from ops_pay_runs o where staff_id = old_id and exists (select 1 from ops_pay_runs n where n.staff_id = new_id and n.ym = o.ym and n.branch_id = o.branch_id);
    delete from ops_sub_offers o where staff_id = old_id and exists (select 1 from ops_sub_offers n where n.staff_id = new_id and n.request_id = o.request_id);

    -- 나머지 기록은 전부 "진짜" 사람 쪽으로 옮김
    update ops_pay_profiles set staff_id = new_id where staff_id = old_id;
    update ops_pay_runs set staff_id = new_id where staff_id = old_id;
    update ops_pay_runs set confirmed_by = new_id where confirmed_by = old_id;
    update ops_sub_offers set staff_id = new_id where staff_id = old_id;
    update ops_shift_patterns set staff_id = new_id where staff_id = old_id;
    update ops_leave_requests set staff_id = new_id where staff_id = old_id;
    update ops_leave_requests set decided_by = new_id where decided_by = old_id;
    update ops_leave_requests set sub_staff_id = new_id where sub_staff_id = old_id;
    update ops_leave_requests set solo_ok_by = new_id where solo_ok_by = old_id;
    update ops_leave_requests set confirmed_by = new_id where confirmed_by = old_id;
    update ops_attendance set staff_id = new_id where staff_id = old_id;
    update ops_attendance set in_by = new_id where in_by = old_id;
    update ops_attendance set out_by = new_id where out_by = old_id;
    update ops_documents set staff_id = new_id where staff_id = old_id;
    update ops_documents set prepared_by = new_id where prepared_by = old_id;
    update ops_health_certs set staff_id = new_id where staff_id = old_id;
    update ops_health_certs set submitted_by = new_id where submitted_by = old_id;
    update ops_health_certs set confirmed_by = new_id where confirmed_by = old_id;
    update ops_staff_purchases set staff_id = new_id where staff_id = old_id;
    if exists (select 1 from information_schema.columns where table_name = 'ops_staff_purchases' and column_name = 'entered_by') then
      update ops_staff_purchases set entered_by = new_id where entered_by = old_id;
    end if;
    update ops_expenses set uploaded_by = new_id where uploaded_by = old_id;
    update ops_stock_checks set staff_id = new_id where staff_id = old_id;
    update ops_orders set ordered_by = new_id where ordered_by = old_id;
    update ops_orders set received_by = new_id where received_by = old_id;
    update ops_transfers set created_by = new_id where created_by = old_id;
    update ops_transfers set received_by = new_id where received_by = old_id;
    update ops_branch_notes set updated_by = new_id where updated_by = old_id;
    if to_regclass('public.ops_subsidy_logs') is not null then
      update ops_subsidy_logs set created_by = new_id where created_by = old_id;
    end if;

    -- 급여 화면의 "사람별 주휴·추가수당" 설정(ops_settings.staff_flags)도 같이 옮김
    update ops_settings
      set value = (value - old_id::text) || jsonb_build_object(new_id::text, coalesce(value -> new_id::text, value -> old_id::text))
      where key = 'staff_flags' and value ? old_id::text;

    -- 중복 줄은 지우지 않고 비활성(퇴사자 칸)으로 내리고, 왜 그런지 메모에 남김
    update manual_staff set active = false,
      memo = coalesce(memo || E'\n', '') || '중복 인물 → "' || r.new_name || '"로 병합됨 (명부 정리 ' || to_char(now(), 'YYYY-MM-DD') || ')'
      where id = old_id;

    raise notice '병합 완료: "%" → "%"', r.old_name, r.new_name;
  end loop;
end $$;

-- 참고: 매뉴얼북(교육 영상 시청 기록 등) 쪽에 이 중복 이름으로 남은 기록이 있다면
-- 이 스크립트가 자동으로 옮기지 못합니다. 필요하면 매뉴얼북 관리자 화면에서 따로 확인해 주세요.
