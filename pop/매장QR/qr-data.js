// 본노엘 매장 QR 주소 모음 — 개별 POP(QR-POP-A5.html)와 종합 한 장(QR모음-A4.html)이 같이 씀.
// 주소 글자는 인쇄물에 절대 쓰지 않음(QR 안에만). 매장 id = manual_branches 실제 id.
var BN_STORES = [
  { name: '성수점', en: 'Seongsu', web: 'seongsu', id: '2ac66e25-8aca-4498-b14b-60a096c86dd9' },
  { name: '답십리점', en: 'Dapsimni', web: 'dapsimni', id: '50834826-ebb4-4bbf-a2d3-9289c90b8634' },
  { name: '중계점', en: 'Junggye', web: 'junggye', id: '2c758126-efce-429d-a430-454c78634862' },
  { name: '왕십리점', en: 'Wangsimni', web: 'wangsimni', id: 'c61bddb3-344c-4bac-9f6a-b39978eaf812' }
];

// key: 파일 끝 #review 처럼 골라 볼 때 쓰는 이름
var BN_QR = {
  review:  function (s) { return 'https://ops.bonnoel.com/?g=' + s.id; },      // 리뷰 이벤트 뽑기 (매장별)
  voice:   function (s) { return 'https://ops.bonnoel.com/?v=' + s.id; },      // 고객의 소리 (매장별)
  allergy: function ()  { return 'https://www.bonnoel.com/b/'; },              // 알레르기·빵 정보 (공통)
  prepay:  function ()  { return 'https://ops.bonnoel.com/prepay.html'; },     // 선결제 안내·잔액 (공통)
  menu:    function (s) { return 'https://www.bonnoel.com/qr/' + s.web; }      // 외국어 메뉴판 (매장별)
};

function bnQrImg(url, cell) {
  var q = qrcode(0, 'M'); q.addData(url); q.make();
  return '<img src="' + q.createDataURL(cell || 10, 0) + '" alt="QR" data-url="' + url + '">';
}
