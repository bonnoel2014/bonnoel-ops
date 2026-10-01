// 법인 서류 양식: 재직증명서 · 경력증명서 · 주주명부. 문구를 고치면 VERSION을 올려 주세요.
// 사용: window.BN_CORP.render(type, ctx) → PDF로 만들 HTML (type: '재직증명서' | '경력증명서' | '주주명부')
// 직인(사용인감): ctx.seal 에 이미지(data URL)가 들어오면 "(인)" 위에 찍히고, 없으면 빈 점선 칸
(function(){
  var VERSION = 'corp-2026-10';

  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function kd(s){ if (!s) return ''; var p = String(s).slice(0, 10).split('-'); return p[0] + '년 ' + (+p[1]) + '월 ' + (+p[2]) + '일'; }
  function birthK(s){ if (!s) return ''; var p = String(s).split('-'); return p.length === 3 ? p[0] + '. ' + p[1] + '. ' + p[2] + '.' : esc(s); }
  function num(n){ n = Number(n) || 0; return n.toLocaleString('ko-KR'); }
  function pct(n, total){ if (!total) return '-'; var v = n / total * 100; return (Math.round(v * 100) / 100).toFixed(2) + '%'; }
  function monthsBetween(a, b){ // 재직 기간 "3년 2개월"
    if (!a) return '';
    var s = new Date(a + 'T00:00:00'), e = new Date((b || new Date().toISOString().slice(0, 10)) + 'T00:00:00');
    var m = (e.getFullYear() - s.getFullYear()) * 12 + (e.getMonth() - s.getMonth()); if (e.getDate() < s.getDate()) m--;
    if (m < 0) return ''; var y = Math.floor(m / 12); m = m % 12;
    return (y ? y + '년 ' : '') + (m || !y ? m + '개월' : '');
  }

  var CSS = '<style>' +
    '.bnc{font-family:"Noto Sans KR","Malgun Gothic",sans-serif;color:#111;background:#fff;font-size:11pt;line-height:1.6}' +
    '.bnc .page{width:190mm;min-height:262mm;padding:2mm 6mm 2mm;box-sizing:border-box;position:relative;display:flex;flex-direction:column}' +
    '.bnc .no{font-size:9pt;color:#444}' +
    '.bnc h1{font-size:24pt;text-align:center;margin:8mm 0 8mm;letter-spacing:14px;font-weight:700}' +
    '.bnc h2{font-size:11pt;margin:10px 0 4px;font-weight:700}' +
    '.bnc table{width:100%;border-collapse:collapse;margin:4px 0 8px;font-size:10.5pt;page-break-inside:avoid}' +
    '.bnc th,.bnc td{border:1px solid #333;padding:6px 8px;vertical-align:middle}' +
    '.bnc th{background:#f3efe8;font-weight:600;text-align:center;white-space:nowrap;width:22%}' +
    '.bnc td.c{text-align:center} .bnc td.r{text-align:right;white-space:nowrap}' +
    '.bnc table.list th{width:auto;padding:6px 4px;font-size:9pt} .bnc table.list td{padding:6px 4px;font-size:9pt} .bnc td.nw{white-space:nowrap}' +
    '.bnc .stmt{text-align:center;font-size:13pt;margin:10mm 0 8mm;word-break:keep-all}' +
    '.bnc .date{text-align:center;font-size:12pt;margin:0 0 8mm}' +
    '.bnc .issuer{display:flex;justify-content:center}' +
    '.bnc .issuer table{width:auto;border:none;margin:0} .bnc .issuer td{border:none;padding:2px 8px;font-size:12pt}' +
    '.bnc .issuer td.k{color:#333;white-space:nowrap}' +
    '.bnc .sealbox{display:inline-block;width:20mm;height:20mm;line-height:20mm;text-align:center;border:1px dashed #bbb;border-radius:4px;color:#999;font-size:10pt;vertical-align:middle;margin-left:8px;position:relative}' +
    '.bnc .sealbox.on{border-color:transparent;color:#333}' +
    '.bnc .sealbox img{max-width:20mm;max-height:20mm;position:absolute;left:0;right:0;top:0;bottom:0;margin:auto}' +
    '.bnc .foot{margin-top:auto;padding-top:4mm;display:flex;align-items:flex-end;gap:10px;border-top:1px solid #ddd;font-size:8.5pt;color:#444;line-height:1.5}' +
    '.bnc .foot img{width:20mm;height:20mm;flex:none}' +
    '.bnc .muted{color:#555}' +
    '</style>';

  function issuerBlock(ctx){
    var c = ctx.company || {};
    var seal = ctx.seal ? '(인)<img src="' + ctx.seal + '" alt="직인">' : '(인)';
    return '<div class="issuer kp"><table>' +
      '<tr><td class="k">회 사 명</td><td>' + esc(c.name) + '</td></tr>' +
      '<tr><td class="k">주 소</td><td>' + esc(c.address) + '</td></tr>' +
      (c.reg_no ? '<tr><td class="k">법인등록번호</td><td>' + esc(c.reg_no) + '</td></tr>' : '') +
      (c.biz_no ? '<tr><td class="k">사업자등록번호</td><td>' + esc(c.biz_no) + '</td></tr>' : '') +
      '<tr><td class="k">대 표 이 사</td><td>' + esc(c.ceo) + ' <span class="sealbox' + (ctx.seal ? ' on' : '') + '">' + seal + '</span></td></tr>' +
      '</table></div>';
  }
  function foot(ctx){
    return '<div class="foot kp">' + (ctx.qr ? '<img src="' + ctx.qr + '" alt="QR">' : '') +
      '<div>발급번호 <b>' + esc(ctx.issueNo || '') + '</b> · 확인 글자 <b>' + esc(ctx.verifyKey || '') + '</b><br>' +
      '이 서류가 진짜인지는 왼쪽 QR을 휴대폰 카메라로 비추거나 아래 주소에서 확인할 수 있습니다.<br>' +
      '<span style="word-break:break-all">' + esc(ctx.verifyUrl || '') + '</span></div></div>';
  }

  function certificate(type, ctx){
    var p = ctx.person || {}, j = ctx.job || {}, career = type === '경력증명서';
    var period = kd(j.hireOn) + ' ~ ' + (career ? kd(j.leaveOn) : '현재') + (j.hireOn ? ' <span class="muted">(' + monthsBetween(j.hireOn, career ? j.leaveOn : ctx.issuedOn) + ')</span>' : '');
    return '<div class="bnc">' + CSS + '<div class="page">' +
      '<div class="no">발급번호 : ' + esc(ctx.issueNo || '') + '</div>' +
      '<h1>' + (career ? '경력증명서' : '재직증명서') + '</h1>' +
      '<h2>1. 인적사항</h2><table>' +
        '<tr><th>성 명</th><td>' + esc(p.name) + '</td><th>생년월일</th><td>' + birthK(p.birth) + '</td></tr>' +
        (p.address ? '<tr><th>주 소</th><td colspan="3">' + esc(p.address) + '</td></tr>' : '') +
      '</table>' +
      '<h2>2. ' + (career ? '경력사항' : '재직사항') + '</h2><table>' +
        '<tr><th>회 사 명</th><td colspan="3">' + esc((ctx.company || {}).name) + '</td></tr>' +
        '<tr><th>소 속</th><td>' + esc(j.branch) + '</td><th>직 위</th><td>' + esc(j.position) + '</td></tr>' +
        '<tr><th>담당업무</th><td colspan="3">' + esc(j.duty) + '</td></tr>' +
        '<tr><th>' + (career ? '근무기간' : '재직기간') + '</th><td colspan="3">' + period + '</td></tr>' +
      '</table>' +
      '<h2>3. 발급 용도</h2><table>' +
        '<tr><th>용 도</th><td>' + esc(ctx.purpose) + '</td><th>제 출 처</th><td>' + esc(ctx.recipient || '') + '</td></tr>' +
      '</table>' +
      '<div class="stmt">위 사람은 당사에 ' + (career ? '위와 같이 근무하였음' : '위와 같이 재직하고 있음') + '을 증명합니다.</div>' +
      '<div class="date">' + kd(ctx.issuedOn) + '</div>' +
      issuerBlock(ctx) + foot(ctx) +
      '</div></div>';
  }

  function shareholders(ctx){
    var rows = (ctx.rows || []).filter(function(r){ return Number(r.shares) > 0; });
    var sum = rows.reduce(function(s, r){ return s + Number(r.shares); }, 0);
    var total = Number(ctx.totalShares) || sum;
    var body = rows.map(function(r, i){
      return '<tr><td class="c">' + (i + 1) + '</td><td class="c">' + esc(r.name) + '</td><td class="c nw">' + birthK(r.birth) + '</td><td>' + esc(r.address || '') + '</td>' +
        '<td class="c">' + esc(r.share_kind || '보통주') + '</td><td class="r">' + num(r.shares) + '</td><td class="r">' + (ctx.parValue ? num(Number(r.shares) * ctx.parValue) : '-') + '</td><td class="r">' + pct(Number(r.shares), total) + '</td><td class="c nw">' + esc(String(r.first_date || '').replace(/-/g, '.')) + '</td></tr>';
    }).join('');
    return '<div class="bnc">' + CSS + '<div class="page">' +
      '<div class="no">발급번호 : ' + esc(ctx.issueNo || '') + '</div>' +
      '<h1 style="margin-bottom:8mm">주 주 명 부</h1>' +
      '<table><tr><th>회 사 명</th><td>' + esc((ctx.company || {}).name) + '</td><th>기 준 일</th><td>' + kd(ctx.asOf) + '</td></tr>' +
      '<tr><th>발행주식 총수</th><td>' + num(total) + '주</td><th>1주의 금액</th><td>' + (ctx.parValue ? num(ctx.parValue) + '원' : '-') + '</td></tr></table>' +
      '<table class="list"><tr><th>번호</th><th>주주명</th><th>생년월일</th><th>주소</th><th>주식 종류</th><th>주식 수</th><th>금액(원)</th><th>지분율</th><th>취득일</th></tr>' + body +
      '<tr><th colspan="5">합 계</th><td class="r"><b>' + num(sum) + '</b></td><td class="r"><b>' + (ctx.parValue ? num(sum * ctx.parValue) : '-') + '</b></td><td class="r"><b>' + pct(sum, total) + '</b></td><td></td></tr></table>' +
      (ctx.purpose ? '<div class="muted" style="font-size:10pt">용도 : ' + esc(ctx.purpose) + (ctx.recipient ? ' · 제출처 : ' + esc(ctx.recipient) : '') + '</div>' : '') +
      '<div class="stmt" style="margin:12mm 0 8mm">위 주주명부는 당사 주주명부와 틀림없음을 확인합니다.</div>' +
      '<div class="date">' + kd(ctx.issuedOn) + '</div>' +
      issuerBlock(ctx) + foot(ctx) +
      '</div></div>';
  }

  function render(type, ctx){ return type === '주주명부' ? shareholders(ctx) : certificate(type, ctx); }

  window.BN_CORP = { version: VERSION, render: render, monthsBetween: monthsBetween };
})();
