// 입사 서류 양식 (노무사 양식을 화면으로 옮긴 것). 문구를 고치면 VERSION을 올려 주세요.
// 사용: window.BN_DOCS.list (서류 목록), window.BN_DOCS.render(key, ctx) → PDF로 만들 HTML
(function(){
  var VERSION = '2026-09';
  var COMPANY = {
    name: '주식회사 본노엘', shortName: '㈜본노엘', ceo: '손성필', phone: '01038151470',
    hq: '서울시 동대문구 전농로75-18',
    sites: [ ['답십리', '서울 동대문구 전농로 75-18'], ['성수', '서울 성동구 상원길 64'], ['왕십리', '서울 성동구 고산자로2길 71'], ['중계', '서울 노원구 한글비석로 245'] ]
  };
  var LIST = [
    { key: 'contract', title: '근로계약서·임금계약서', checks: [
      { id: 'ot', text: '제4조에 따른 연장·야간·휴일근로 실시에 동의합니다' },
      { id: 'served', text: '근로계약서와 임금계약서를 서면(전자문서)으로 교부받았습니다' } ] },
    { key: 'privacy', title: '개인정보 수집·이용 동의서', checks: [
      { id: 'p1', text: '개인정보의 수집·이용에 동의합니다' },
      { id: 'p2', text: '민감정보의 수집·이용에 동의합니다' },
      { id: 'p3', text: '고유식별정보의 수집·이용에 동의합니다' },
      { id: 'p4', text: '개인정보의 내부 이용·외부 제공(2항)에 동의합니다' } ] },
    { key: 'pledge', title: '서약서', checks: [
      { id: 'ok', text: '위 서약 사항을 세심히 확인했으며, 자유로운 의사로 작성합니다' } ] },
    { key: 'cctv', title: 'CCTV 영상정보 수집 동의서', checks: [
      { id: 'all', text: '영상정보 수집에 관한 설명을 모두 이해했으며 전체 항목에 동의합니다' } ] },
    { key: 'uniform', title: '유니폼 지급대장', checks: [
      { id: 'recv', text: '위 물품을 지급받았으며, 퇴사 시 반납하겠습니다' } ] },
    { key: 'guardian', title: '친권자(후견인) 동의서', minorOnly: true, guardianSign: true, checks: [] }
  ];

  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function kd(s){ // '2026-09-19' → '2026년 9월 19일'
    if (!s) return '<span class="bl">____년 __월 __일</span>';
    var p = s.split('-'); return p[0] + '년 ' + (+p[1]) + '월 ' + (+p[2]) + '일';
  }
  function v(s, w){ return s ? esc(s) : '<span class="bl" style="min-width:' + (w || 60) + 'px"></span>'; }
  function won(n){ n = Number(n) || 0; return n.toLocaleString('ko-KR'); }
  function box(on){ return on ? '☑' : '□'; }
  function sig(img, name, label){ // 서명 자리: 이미지가 있으면 찍고 없으면 빈칸
    return '<span class="sigspot">' + (label ? label + ' ' : '') + (name ? esc(name) + ' ' : '') + (img ? '<img class="sig" src="' + img + '" alt="서명">' : '<span class="bl" style="min-width:70px"></span>') + '<span class="muted">(서명)</span></span>';
  }
  function seal(ctx){ return ctx.seal ? '<img class="seal" src="' + ctx.seal + '" alt="직인">' : '<span class="muted">(인)</span>'; }
  function age(birth, on){ if (!birth) return null; var b = new Date(birth + 'T00:00:00'), d = new Date((on || new Date().toISOString().slice(0, 10)) + 'T00:00:00'); var a = d.getFullYear() - b.getFullYear(); if (d.getMonth() < b.getMonth() || (d.getMonth() === b.getMonth() && d.getDate() < b.getDate())) a--; return a; }

  var CSS = '<style>' +
    '.bnd{font-family:"Noto Sans KR","Malgun Gothic",sans-serif;color:#111;background:#fff;font-size:10pt;line-height:1.5}' +
    '.bnd .page{width:190mm;padding:2mm 3mm 4mm;box-sizing:border-box;background:#fff;page-break-after:always;position:relative}' +
    '.bnd .page:last-child{page-break-after:auto}' +
    '.bnd h1{font-size:19pt;text-align:center;margin:0 0 12px;letter-spacing:6px;font-weight:700}' +
    '.bnd h2{font-size:10.5pt;margin:9px 0 2px;font-weight:700}' +
    '.bnd p{margin:0 0 4px;text-align:justify;word-break:keep-all}' +
    '.bnd .kp{page-break-inside:avoid}' +
    '.bnd table{width:100%;border-collapse:collapse;margin:6px 0;font-size:9.5pt;page-break-inside:avoid}' +
    '.bnd th,.bnd td{border:1px solid #333;padding:3px 5px;vertical-align:middle}' +
    '.bnd th{background:#f0ede6;font-weight:600;text-align:center;white-space:nowrap}' +
    '.bnd td.c{text-align:center}' +
    '.bnd .bl{display:inline-block;border-bottom:1px solid #333;min-width:60px;height:1em;vertical-align:baseline}' +
    '.bnd .muted{color:#555}' +
    '.bnd .date{text-align:center;margin:16px 0 10px;font-size:11pt}' +
    '.bnd .signrow{display:flex;justify-content:space-between;align-items:flex-end;gap:12px;margin-top:8px;flex-wrap:wrap}' +
    '.bnd .sigspot{display:inline-flex;align-items:flex-end;gap:6px;white-space:nowrap}' +
    '.bnd img.sig{height:34px;width:auto;vertical-align:bottom}' +
    '.bnd img.seal{height:30px;width:auto;vertical-align:middle}' +
    '.bnd .box{border:1px solid #333;padding:8px 10px;margin:6px 0}' +
    '.bnd .center{text-align:center}' +
    '.bnd .right{text-align:right}' +
    '.bnd .small{font-size:9pt}' +
    '.bnd .foot{margin-top:14px;border-top:1px solid #ccc;padding-top:4px;font-size:8pt;color:#666;display:flex;justify-content:space-between}' +
    '</style>';

  function foot(ctx, title){
    return '<div class="foot"><span>' + esc(title) + ' · 양식 ' + VERSION + '</span><span>' + (ctx.signedAt ? '전자서명 ' + esc(ctx.signedAt) + (ctx.signedTime ? ' ' + esc(ctx.signedTime) : '') : '') + (ctx.docId ? ' · 문서번호 ' + esc(String(ctx.docId).slice(0, 8)) : '') + '</span></div>';
  }

  // ---------- 근로계약서 + 임금계약서 ----------
  function contract(ctx){
    var s = ctx.staff || {}, c = ctx.c || {}, ch = ctx.checks || {};
    var days = c.days || {};
    var wd = ['일', '월', '화', '수', '목', '금', '토'];
    function dayRow(i){
      var d = days[i] || {};
      var brk = d.brk === 60 ? '(☑60분 / □30분 / □없음)' : d.brk === 30 ? '(□60분 / ☑30분 / □없음)' : d.brk === 0 && d.s ? '(□60분 / □30분 / ☑없음)' : '(□60분 / □30분 / □없음)';
      return '<td class="c"><b>' + wd[i] + '</b></td><td class="c">' + (d.s ? esc(d.s) : '<span class="muted">—</span>') + '</td><td class="c">' + (d.e ? esc(d.e) : '<span class="muted">—</span>') + '</td><td class="c small">' + (d.s ? '근무시간 중 ' + brk : '<span class="muted">휴무</span>') + '</td>';
    }
    var siteNote = c.branchName ? ' (주된 근무지: ' + esc(c.branchName) + (c.branchAddr ? ' ' + esc(c.branchAddr) : '') + ')' : '';
    var h = '<div class="page">' +
      '<h1>근로계약서</h1>' +
      '<p>' + COMPANY.name + ' (이하 “사용자”이라 한다)과 근로자 <b>' + v(s.name, 70) + '</b> (이하 “근로자”이라 한다)은 상호 동등한 지위에서 자유의사로 다음과 같은 근로조건으로 근로계약을 체결하고 상호간에 성실히 이행할 것을 약속한다.</p>' +
      '<h2>제1조【계약기간】</h2>' +
      '<p>① 계약기간 : ' + kd(c.start) + ' 부터 ~ ' + (c.end ? kd(c.end) : '<span class="bl">____년 __월 __일</span>') + ' 까지 (*기간에 정함이 없는 근로계약의 경우 계약기간 만료일을 적지 아니한다. 계약기간의 정함이 있는 경우 기간만료와 동시에 근로관계는 당연 종료되며, 사용자는 계약을 갱신할 의무가 없다.)</p>' +
      '<h2>제2조【수습기간】</h2>' +
      (c.probation === false ? '<p>① 수습기간은 두지 아니한다.</p>' : '<p>① 수습기간은 입사일로부터 3개월로 한다. 다만, 수습기간 중 별도의 평가안에 따라 해당직무 수행에 필요한 지식, 능력 및 업무 적격성을 평가하여 본계약을 해지할 수 있다.</p>') +
      '<h2>제3조【근무장소 및 담당업무】</h2>' +
      '<p>① 근무장소 : 사용자의 사업장 및 영업장소' + siteNote + '</p>' +
      '<p>② 담당업무 : ' + v(c.duty || '매장관리 및 운영업무', 120) + '</p>' +
      '<p>③ 사용자는 업무상 필요하다고 인정할 경우 근로자의 근무장소 및 담당업무 등을 변경할 수 있으며, 근로자는 특별한 사유가 없는 한 이를 따라야 한다.</p>' +
      '<h2>제4조【근로시간 및 휴게시간】</h2>' +
      '<p>① 요일별 근무시간 및 휴게시간은 다음과 같고, 업무사정에 따른 연장.야간.휴일근로를 실시할 수 있으며, 동의를 본 서명으로 갈음한다.</p>' +
      '<p>② 근로일 및 근무시간, 휴게시간 등은 사용자의 사정 및 근무여건 등에 따라 변경될 수 있다.</p>' +
      '<p>③ 약정된 근무시간 외 시간외근로(연장.야간.휴일근로)는 사용자의 사전동의를 원칙으로 하며 부득이한 경우는 즉시 사후보고를 해야한다. 사전동의 내지 사후보고가 없을 경우 근로시간으로 인정되지 아니한다.</p>' +
      '<p>④ 휴게시간은 사용자의 사업장 특성상 시업시간과 종업시간 사이에 부여된 시간을 사용하며, 사업장 상황에 따라 휴게시간의 분할 사용이 가능하다.</p>' +
      '<table><tr><th rowspan="3" style="width:52px">사용자</th><th>사업체명</th><td>' + COMPANY.name + '</td><th>대표자</th><td>' + COMPANY.ceo + '</td></tr>' +
      '<tr><th>소재지</th><td colspan="3" class="small">' + COMPANY.sites.map(function(x){ return x[0] + ') ' + x[1]; }).join('<br>') + '</td></tr>' +
      '<tr><th>연락처</th><td colspan="3">' + COMPANY.phone + '</td></tr>' +
      '<tr><th rowspan="3">근로자</th><th>성명</th><td>' + v(s.name) + '</td><th>주민등록번호</th><td>' + (s.residentNumber ? esc(s.residentNumber) : '<span class="small muted">별도 서면 제출</span>') + '</td></tr>' +
      '<tr><th>연락처</th><td>' + v(s.phone) + '</td><th>입사일</th><td>' + (c.start ? kd(c.start) : v('')) + '</td></tr>' +
      '<tr><th>주소</th><td colspan="3">' + v(s.address, 200) + '</td></tr></table>' +
      foot(ctx, '근로계약서') +
      '</div>';
    h += '<div class="page">' +
      '<table><tr><th>요일</th><th>시업시간</th><th>종업시간</th><th>휴게시간</th></tr>' +
      [1, 2, 3, 4, 5, 6, 0].map(function(i){ return '<tr>' + dayRow(i) + '</tr>'; }).join('') + '</table>' +
      '<p class="small">※연장.야간.휴일근로 동의 ' + box(ch.ot) + ' &nbsp; ' + sig(ctx.sig, s.name, '【동의자 성명(서명)】') + '</p>' +
      '<p>⑤ 약정된 근로일에 부득이한 사정으로 결근 시 본인의 책임하에 대체 근무자를 확보한 후 휴무하여야 한다.</p>' +
      '<h2>제5조【휴일 및 휴가】</h2>' +
      '<p>① 1주 소정근로일을 개근하지 않았거나 1주 소정근로시간이 15시간 미만인 경우 주휴일의 적용이 없다.</p>' +
      '<p>② 기타 휴일 및 휴가에 관한 구체적인 사항은 근로기준법에 따른다.</p>' +
      '<h2>제6조【직무상 내용 및 영업비밀 등 유지의무】</h2>' +
      '<p>근로자는 업무수행 중 직무상 내용, 영업비밀을 유지할 의무를 부담하며, 퇴직 후에도 사용자의 직무상 내용, 영업비밀을 유지하며 이를 타인에게 발설하여 사용자에게 손해가 발생한 경우 이에 대하여 배상책임을 진다.</p>' +
      '<h2>제7조【근로계약의 해지】</h2>' +
      '<p>① 사용자의 정당한 업무명령을 근로자가 거부하거나 위반한 경우</p>' +
      '<p>② 근로자가 정당하지 아니한 집단행동 및 태업을 선동하는 행위</p>' +
      '<p>③ 근로자의 복장이 단정하지 않게 관리되어 불쾌감을 주는 경우</p>' +
      '<p>④ 근로자가 이력, 경력을 위조하여 허위로 입사한 경우</p>' +
      '<p>⑤ 근로자의 계약기간이 만료 된 경우</p>' +
      '<p>⑥ 도급, 위탁 등 계약이 정해져 있는 사업을 수행하던 중 그 사업 수행 계약기간이 종료된 경우</p>' +
      '<p>⑦ 근로자의 무단결근이 2회 이상 발생한 경우</p>' +
      '<p>⑧ 잦은 지각, 결근으로 업장에 피해를 주는 경우</p>' +
      '<p>⑨ 기타 사회통념상 근로관계를 지속하지 못하는 사유가 발생하는 경우</p>' +
      '<h2>제8조【근로자의 근로계약 해지 통보】</h2>' +
      '<p>① 근로자는 사용자와 근로계약을 해지하고자 하는 경우, 근로관계 종료일 30일 전에 사직서를 제출하면서 해지통보를 하여야 하며 미준수로 인하여 사용자에게 손해가 발생한 경우 근로자는 통상손해는 물론 특별한 사정으로 인한 특별손해에 대해서도 배상책임을 진다.</p>' +
      '<h2>제9조【개인정보수집 및 이용 동의】</h2>' +
      '<p>근로자는 사용자가 근로자의 4대보험 취득상실, 임금지급, 인사관리 등을 위해 반드시 필요한 개인정보(주민번호 포함)의 수집 및 이용에 동의한다.</p>' +
      '<h2>제10조【근로계약서, 임금계약서 서면교부 확인】</h2>' +
      '<p>근로자는 근로기준법 제17조 제2항에 따라 본 근로계약서 및 임금계약서를 서면으로 교부받았음을 확인한다. ' + box(ch.served) + '</p>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span>【사용자】 ' + COMPANY.name + ' 대표 ' + COMPANY.ceo + ' ' + seal(ctx) + '</span>' + sig(ctx.sig, s.name, '【근로자】') + '</div>' +
      foot(ctx, '근로계약서') +
      '</div>';
    var minWage = 10320;
    h += '<div class="page">' +
      '<h1>임금계약서</h1>' +
      '<p>' + COMPANY.name + ' (이하 “사용자”이라 한다)과 근로자 <b>' + v(s.name, 70) + '</b> (이하 “근로자”이라 한다)은 다음과 같이 임금계약을 체결하고 계약사항을 성실히 이행할 것을 약속한다.</p>' +
      '<h2>제1조【계약기간】</h2>' +
      (c.wageEnd ?
        '<p>① 임금계약기간은 ' + kd(c.start) + ' 부터 ' + kd(c.wageEnd) + ' 까지로 한다.</p>' +
        '<p>② 계약기간이 종료된 이후 근로자의 업적성과, 매출 등 경영상태를 고려하여 임금을 조정할 수 있다. 계약기간이 종료된 후 1개월 내에 임금이 조정되지 않은 경우, 동일한 기간과 동일한 금액으로 임금계약이 갱신된 것으로 한다.</p>'
        :
        '<p>① 임금계약기간은 ' + kd(c.start) + ' 부터로 하며, 기간을 정하지 아니한다. (*근로계약과 같은 기간으로 본다)</p>' +
        '<p>② 임금은 근무년도 최저임금 변경, 근로자의 업적성과, 매출 등 경영상태를 고려하여 조정할 수 있다.</p>'
      ) +
      '<h2>제2조【급여 및 구성항목】</h2>' +
      '<p>① 근로자의 급여는 시급 <b>' + won(c.wage) + '원</b>' + (Number(c.wage) === minWage ? '(*근무년도 최저임금)' : '') + '으로 한다.</p>' +
      '<p>② 근로기준법에서 정하는 바에 따라 주휴수당을 지급하며, 임금의 구성항목은 기본급과 식대로 구성한다.</p>' +
      '<p>③ 월 총 급여에서 ' + won(c.meal == null ? 200000 : c.meal) + '원을 식대로 배정한다.</p>' +
      '<p>④ 법령(4대보험, 근로소득세 등) 및 노사 합의에 의한 금액은 공제하고 근로자에게 직접 지급하거나 근로자가 지정한 본인 명의의 예금계좌에 입금한다.</p>' +
      '<p>⑤ 무노동·무임금 원칙에 따라 근로자가 결근, 지각, 조퇴, 외출 등을 하는경우 임금은 발생하지 않는다.</p>' +
      '<p>⑥ 임금의 산정기간은 매월 초일부터 말일까지로 하며 익월 ' + (c.payDay || 10) + '일 오후 11시경에 이를 지급한다. (*임금지급일이 휴무일/휴일인 경우 그 다음날 지급)</p>' +
      '<p>⑦ 퇴사의 경우에도 지급기일은 매월 지급하는 일자까지 연장하는 것에 동의한다.</p>' +
      '<h2>제3조【퇴직금】</h2>' +
      '<p>사용자는 근로자가 1년 이상 근속한 경우 근로자퇴직급여보장법에 따라 계속근로기간 1년에 대하여 평균임금 30일분의 퇴직금을 지급하거나, 퇴직금 지급에 갈음하여 퇴직연금에 가입하고 근로자의 퇴직시에 연금 또는 일시금으로 지급한다.</p>' +
      '<h2>제4조【기타】</h2>' +
      '<p>① 사용자와 근로자는 임금내역을 타인에게 누설하지 않는다.</p>' +
      '<p>② 이 계약에 정함이 없는 사항은 근로기준법 등 노동관계법령 및 취업규칙에 따른다.</p>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span>【사용자】 ' + COMPANY.name + ' 대표 ' + COMPANY.ceo + ' ' + seal(ctx) + '</span>' + sig(ctx.sig, s.name, '【근로자】') + '</div>' +
      foot(ctx, '임금계약서') +
      '</div>';
    return h;
  }

  // ---------- 개인정보 수집·이용 동의서 ----------
  function privacy(ctx){
    var s = ctx.staff || {}, ch = ctx.checks || {};
    var keep = '재직기간 동안 보유하고, 기타 개별법령에서 보유기간을 정하고 있는 경우 그에 따름';
    function tbl(h1, items, purposes){
      return '<table><tr><th style="width:34%">' + h1 + '</th><th style="width:36%">수집·이용 목적</th><th>보유기간</th></tr>' +
        '<tr><td class="small">' + items.join('<br>') + '</td><td class="small">' + purposes.join('<br>') + '</td><td class="small">' + keep + '</td></tr></table>';
    }
    function agree(on){ return '( ' + (on ? '☑동의함 &nbsp;□동의하지 않음' : '□동의함 &nbsp;☑동의하지 않음') + ' )'; }
    return '<div class="page">' +
      '<h1>개인정보 수집·이용에 관한 동의</h1>' +
      '<p>1. <b>' + v(s.name, 70) + '</b> 은(는) ' + COMPANY.shortName + '의 재직근로자로서 인사관리상 개인정보의 수집·이용이 필요하다는 것을 이해하고 있고, 다음과 같이 개인정보·민감정보·고유식별정보를 수집·이용하는 것에 동의합니다.</p>' +
      tbl('개인정보항목', ['가. 성명', '나. 주소, 이메일, 연락처', '다. 학력, 근무경력, 자격증', '라. 기타 근무와 관련된 개인정보'], ['가. 채용 및 승진 등 인사관리', '나. 세법, 노동관계법령 등에서 부과하는 의무이행', '다. 급여관리', '라. 정부지원금 신청']) +
      '<p class="right">개인정보의 수집·이용에 ' + agree(ch.p1) + '</p>' +
      tbl('민감정보의 항목', ['가. 신체장애', '나. 병력', '다. 범죄정보'], ['가. 채용 및 승진 등 인사관리', '나. 세법, 노동관계법령 등에서 부과하는 의무이행', '다. 정부지원금 신청']) +
      '<p class="right">민감정보의 수집·이용에 ' + agree(ch.p2) + '</p>' +
      tbl('고유식별정보', ['가. 주민등록번호', '나. 운전면허번호', '다. 여권번호', '라. 외국인등록번호'], ['가. 채용 및 승진 등 인사관리', '나. 세법, 노동관계법령 등에서 부과하는 의무이행', '다. 급여관리', '라. 정부지원금 신청']) +
      '<p class="right">고유식별정보의 수집·이용에 ' + agree(ch.p3) + '</p>' +
      '<p>2. <b>' + v(s.name, 70) + '</b> 은(는) ' + COMPANY.shortName + '가(이) 취득한 개인정보를 재직기간 동안 내부적으로 채용·승진 등 인사관리에 이용하고, 외부적으로 법령에 따라 관계기관 또는 급여관리에 관한 외부전문기관에 제공하는 것에 동의합니다.</p>' +
      '<p class="right">개인정보의 수집·이용에 ' + agree(ch.p4) + '</p>' +
      '<p>3. 본사는 취득한 개인정보를 수집한 목적에 필요한 범위에서 적합하게 처리하고 그 목적 외의 용도로 사용하지 않으며, 개인 정보를 제공한 계약당사자는 언제나 자신이 입력한 개인정보를 열람·수정 및 정보제공에 대한 철회를 할 수 있습니다.</p>' +
      '<p>4. 본인은 1~3항에 따라 수집되는 개인정보의 항목과 개인정보의 수집·이용에 대한 거부를 할 수 있는 권리가 있다는 사실을 충분히 설명 받고 숙지하였으며, 미동의시 적법하게 시행되는 회사내부규정 및 법령에 따라 발생하는 불이익에 대한 책임은 본인에게 있음을 확인합니다.</p>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span></span>' + sig(ctx.sig, s.name, '동의자 성명 :') + '</div>' +
      foot(ctx, '개인정보 수집·이용 동의서') +
      '</div>';
  }

  // ---------- 서약서 ----------
  function pledge(ctx){
    var s = ctx.staff || {};
    return '<div class="page">' +
      '<h1>서 약 서</h1>' +
      '<p class="right">성 명 : <b>' + v(s.name, 70) + '</b> &nbsp;&nbsp; 생년월일 : ' + (s.birth ? kd(s.birth) : v('')) + '</p>' +
      '<p>본인은 ' + COMPANY.shortName + '의 직원으로 아래의 사항을 준수할 것을 서약합니다.</p>' +
      '<p class="center">- 아 &nbsp; 래 -</p>' +
      '<p>1. 본인은 사원으로서 사규를 엄격히 준수 할 것이며, 만일 사규를 위반 할 시에는 어떠한 처벌도 감수 할 것입니다.</p>' +
      '<p>2. 본인은 사측이 인원축소, 근무형태 변경, 근무지 변경 등을 필요로 할 때 법인의 방침과 지시에 순응하겠습니다.</p>' +
      '<p>3. 본인은 공사를 막론하고 거래처와 물적, 금전적인 수수행위나 향응을 받음으로 인해 사원총화를 해치는 행위를 하였을 시는 어떠한 처벌도 감수하겠습니다.</p>' +
      '<p>4. 본인은 회사의 승인 없이 액면의 과다를 막론하고 공금 및 회사 자산을 유용하여 ' + COMPANY.shortName + '에 손해를 초래하였을 시에는 어떠한 처벌도 감수하겠습니다.</p>' +
      '<p>5. 본인은 영업비밀 등의 보호와 관련하여 다음과 같이 서약합니다.</p>' +
      '<p style="padding-left:12px">1) 본인은 업무수행중 또는 업무와 관련 없이 취득하게 되는 다음과 같은 사항 및 기타 영업비밀을 지정된 업무에 사용하는 경우를 제외하고는 어떠한 방법으로도 회사 내외의 제3자에게 누설하거나 공개하지 않겠습니다(다만, 법인의 사전 서면동의가 있거나 영업비밀보호관련 규정에 의해 허용된 경우는 예외로 함).</p>' +
      '<p style="padding-left:24px">- 인사, 조직 및 재무현황, 생산․판매현황, 마케팅 기법 등 경영상의 정보<br>- 제품·서비스의 설계방법, 설계도면, 창작물 등과 관련된 기술상의 정보 및 저작물</p>' +
      '<p style="padding-left:12px">2) 본인은 재직중 영업비밀이 누설될 수 있는 동종․유사업체의 임직원을 겸직하거나 자문․고문 기타 방법으로 해당 업체에 협력하지 않겠으며, 퇴직 이후에도 재직중에 취득한 영업비밀을 제3자에게 누설하거나 공개하지 않겠습니다.</p>' +
      '<p style="padding-left:12px">3) 본인은 법인의 영업비밀 보호를 위하여, 적어도 퇴직일로부터 2년 동안은 회사의 사전 서면동의 없이 퇴직일 현재 법인의 제품 및 서비스와 동일하거나 유사한 업체를 스스로 창업하거나, 이와 같은 업체에 취업하지 않겠습니다.</p>' +
      '<p>6. 본인은 법인을 퇴직한 후라도 조직질서 문란행위, 성실의무위반, 근로관계해지통보기간 미준수 등 재직시 본인의 고의 또는 과실로 인하여 법인에 손해가 발생하였을 시에는 민, 형사상의 책임을 질것이며 모든 민, 형사상의 책임 문제는 본사가 소재한 주소지의 관할 법원에서 처리하는 것을 원칙으로 합니다.</p>' +
      '<p>서명에 앞서 위 서약사항을 세심히 확인하였으며, 본인의 자유로운 의사에 기해 본 서약서를 작성함을 확인합니다.</p>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span></span>' + sig(ctx.sig, s.name, '확인자 성명') + '</div>' +
      '<p class="right" style="margin-top:14px">' + COMPANY.name.replace('주식회사 ', '') + ' 주식회사 &nbsp;대표이사 귀하</p>' +
      foot(ctx, '서약서') +
      '</div>';
  }

  // ---------- CCTV 영상정보 수집 동의서 ----------
  function cctv(ctx){
    var s = ctx.staff || {}, ch = ctx.checks || {};
    return '<div class="page">' +
      '<h1>CCTV 영상 정보 수집 동의서</h1>' +
      '<p><b>□ 개인정보의 수집 및 이용에 대한 동의(체크)</b></p>' +
      '<table><tr><th style="width:38%">□ 수 집 항 목 (필수항목)</th><td>• 영상 정보</td></tr>' +
      '<tr><th>□ 수집·이용목적</th><td>• 사업장의 보안과 근로자의 안전<br>• 영업비밀 유출 및 도난 방지</td></tr>' +
      '<tr><th>□ 개인정보의 보유 및 이용기간</th><td>• 퇴사후 3개월까지</td></tr>' +
      '<tr><th>□ 영상정보의 별도의 이용 동의</th><td>• 감시의 목적으로 사용하지 않는 범위내에서 직장질서를 해하는 경우 징계 사유의 증거로 사용 될 수 있음에 동의</td></tr></table>' +
      '<p style="margin-top:14px">전체 항목에 동의합니다 ' + box(ch.all) + '.</p>' +
      '<p>본인은 “영상정보 수집”에 관한 설명을 모두 이해하였으며, 이에 동의합니다.</p>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span></span>' + sig(ctx.sig, s.name, '성명 :') + '</div>' +
      '<p class="right" style="margin-top:14px">' + COMPANY.name.replace('주식회사 ', '') + ' 주식회사 대표 귀중</p>' +
      '<p class="small muted">※ 반드시 자필 서명 후 제출</p>' +
      foot(ctx, 'CCTV 영상정보 수집 동의서') +
      '</div>';
  }

  // ---------- 유니폼 지급대장 (노무사 양식 없음 → 앱에서 만든 표. 노무사 확인 필요) ----------
  function uniform(ctx){
    var s = ctx.staff || {}, ch = ctx.checks || {}, items = (ctx.uniform || []).filter(function(x){ return x && x.item; });
    var rows = items.length ? items.map(function(x, i){ return '<tr><td class="c">' + (i + 1) + '</td><td>' + esc(x.item) + '</td><td class="c">' + esc(x.size || '-') + '</td><td class="c">' + esc(x.qty || 1) + '</td><td class="c">' + kd(x.date || ctx.signedAt) + '</td></tr>'; }).join('') : '<tr><td colspan="5" class="c muted">지급 물품 없음</td></tr>';
    return '<div class="page">' +
      '<h1>유니폼 지급대장</h1>' +
      '<table><tr><th style="width:18%">성명</th><td>' + v(s.name) + '</td><th style="width:18%">근무지</th><td>' + v(ctx.c && ctx.c.branchName) + '</td></tr>' +
      '<tr><th>입사일</th><td>' + (ctx.c && ctx.c.start ? kd(ctx.c.start) : v('')) + '</td><th>연락처</th><td>' + v(s.phone) + '</td></tr></table>' +
      '<table><tr><th style="width:8%">번호</th><th>품목</th><th style="width:14%">사이즈</th><th style="width:12%">수량</th><th style="width:26%">지급일</th></tr>' + rows + '</table>' +
      '<div class="box small"><p>1. 위 물품은 ' + COMPANY.name + '의 소유이며, 근무 중 착용·사용합니다.</p>' +
      '<p>2. 퇴사 시 지급받은 물품을 반납합니다.</p>' +
      '<p>3. 위 물품을 지급받았음을 확인합니다. ' + box(ch.recv) + '</p></div>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span>지급자 : ' + COMPANY.name + ' ' + v(ctx.c && ctx.c.preparedBy, 60) + '</span>' + sig(ctx.sig, s.name, '수령자 :') + '</div>' +
      foot(ctx, '유니폼 지급대장') +
      '</div>';
  }

  // ---------- 친권자(후견인) 동의서 (만 18세 미만) ----------
  function guardian(ctx){
    var s = ctx.staff || {}, g = ctx.guardian || {};
    var a = age(s.birth, ctx.signedAt);
    return '<div class="page">' +
      '<h1>친권자(후견인) 동의서</h1>' +
      '<h2>○ 친권자(후견인) 인적사항</h2>' +
      '<table><tr><th style="width:26%">성 명</th><td>' + v(g.name) + '</td></tr><tr><th>생년월일</th><td>' + (g.birth ? kd(g.birth) : v('')) + '</td></tr><tr><th>주 소</th><td>' + v(g.address, 200) + '</td></tr><tr><th>연 락 처</th><td>' + v(g.phone) + '</td></tr><tr><th>연소근로자와의 관계</th><td>' + v(g.relation) + '</td></tr></table>' +
      '<h2>○ 연소근로자 인적사항</h2>' +
      '<table><tr><th style="width:26%">성 명</th><td>' + v(s.name) + (a != null ? ' (만 ' + a + '세)' : ' (만 &nbsp;&nbsp;&nbsp; 세)') + '</td></tr><tr><th>생년월일</th><td>' + (s.birth ? kd(s.birth) : v('')) + '</td></tr><tr><th>주 소</th><td>' + v(s.address, 200) + '</td></tr><tr><th>연 락 처</th><td>' + v(s.phone) + '</td></tr></table>' +
      '<h2>○ 사업장 개요</h2>' +
      '<table><tr><th style="width:26%">회 사 명</th><td>' + COMPANY.name + '</td></tr><tr><th>회사주소</th><td>' + COMPANY.hq + '</td></tr><tr><th>대 표 자</th><td>' + COMPANY.ceo + '</td></tr><tr><th>회사전화</th><td>' + COMPANY.phone + '</td></tr></table>' +
      '<p style="margin-top:14px">본인은 위 연소근로자 <b>' + v(s.name, 70) + '</b> 가(이) 위 사업장에서 근로를 하는 것에 대하여 동의합니다.</p>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span></span>' + sig(ctx.gsig, g.name, '친권자(후견인)') + '</div>' +
      (ctx.gsig ? '' : '<p class="small muted" style="margin-top:10px">※ 친권자(후견인)가 자필 서명한 뒤 제출해 주세요.</p>') +
      '<p class="small" style="margin-top:14px">첨 부 : 가족관계증명서 1부 또는 주민등록등본 1부</p>' +
      foot(ctx, '친권자(후견인) 동의서') +
      '</div>';
  }

  // ---------- 유니폼 반납확인서 (퇴사 시. 입사 서류 6종에는 안 들어가고 따로 만듦) ----------
  function uniformReturn(ctx){
    var s = ctx.staff || {}, ch = ctx.checks || {}, items = (ctx.uniform || []).filter(function(x){ return x && x.item && num2(x.qty) > 0; });
    var rows = items.length ? items.map(function(x, i){ return '<tr><td class="c">' + (i + 1) + '</td><td>' + esc(x.item) + '</td><td class="c">' + esc(x.size || '-') + '</td><td class="c">' + esc(x.qty || 1) + '</td></tr>'; }).join('') : '<tr><td colspan="4" class="c muted">반납 물품 없음</td></tr>';
    return '<div class="page">' +
      '<h1>유니폼 반납확인서</h1>' +
      '<table><tr><th style="width:18%">성명</th><td>' + v(s.name) + '</td><th style="width:18%">근무지</th><td>' + v(ctx.c && ctx.c.branchName) + '</td></tr>' +
      '<tr><th>연락처</th><td>' + v(s.phone) + '</td><th>반납일</th><td>' + (ctx.returnDate ? kd(ctx.returnDate) : kd(ctx.signedAt)) + '</td></tr></table>' +
      '<table><tr><th style="width:10%">번호</th><th>품목</th><th style="width:16%">사이즈</th><th style="width:14%">수량</th></tr>' + rows + '</table>' +
      '<div class="box small"><p>1. 위 물품은 근무 중 지급받아 사용한 ' + COMPANY.name + ' 소유 물품입니다.</p>' +
      '<p>2. 근무 종료(퇴사)에 따라 위 물품을 반납하였음을 확인합니다. ' + box(ch.returned !== false) + '</p></div>' +
      '<div class="date">' + kd(ctx.signedAt) + '</div>' +
      '<div class="signrow kp"><span>확인자 : ' + COMPANY.name + ' ' + v(ctx.c && ctx.c.confirmedBy, 60) + ' ' + seal(ctx) + '</span>' + sig(ctx.sig, s.name, '반납자 :') + '</div>' +
      foot(ctx, '유니폼 반납확인서') +
      '</div>';
  }
  function num2(n){ n = Number(n); return isNaN(n) ? 0 : n; }

  var R = { contract: contract, privacy: privacy, pledge: pledge, cctv: cctv, uniform: uniform, guardian: guardian, uniform_return: uniformReturn };
  window.BN_DOCS = {
    version: VERSION, company: COMPANY, list: LIST, css: CSS, age: age,
    byKey: function(k){ return LIST.filter(function(d){ return d.key === k; })[0]; },
    render: function(key, ctx){ return CSS + '<div class="bnd">' + (R[key] ? R[key](ctx || {}) : '<div class="page">알 수 없는 서류</div>') + '</div>'; }
  };
})();
