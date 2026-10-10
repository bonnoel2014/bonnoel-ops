// 매장 QR POP 뽑기:  node make.mjs        (이 폴더에서 실행, 윈도우 Edge 필요)
// 결과: pdf/ 에 인쇄용 PDF, png/ 에 미리보기 그림
//  - QR-POP-<종류>-A5.pdf : 종류별 4매장 4쪽 (A5)
//  - QR모음-A4.pdf        : 매장별 종합 한 장 4쪽 (A4)
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const edge = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const pdfDir = path.join(here, 'pdf'), pngDir = path.join(here, 'png');
fs.mkdirSync(pdfDir, { recursive: true }); fs.mkdirSync(pngDir, { recursive: true });

const KINDS = { review: '리뷰이벤트', voice: '고객의소리', allergy: '알레르기', prepay: '선결제', menu: '외국어메뉴' };
const STORES = ['성수점', '답십리점', '중계점', '왕십리점'];
const url = (file, hash) => pathToFileURL(path.join(here, file)).href + '#' + encodeURIComponent(hash).replace(/%2F/g, '/');
const prof = path.join(process.env.TEMP || here, 'bonnoel-edge-headless');   // 사용 중인 Edge와 안 겹치게
const base = ['--headless', '--user-data-dir=' + prof, '--disable-gpu', '--hide-scrollbars', '--no-pdf-header-footer', '--virtual-time-budget=10000'];
const run = (args) => execFileSync(edge, [...base, ...args], { stdio: 'ignore' });

for (const [k, ko] of Object.entries(KINDS)) {
  run([`--print-to-pdf=${path.join(pdfDir, `QR-POP-${ko}-A5.pdf`)}`, url('QR-POP-A5.html', k)]);
  for (const s of STORES)
    run(['--force-device-scale-factor=2', '--window-size=560,794', `--screenshot=${path.join(pngDir, `QR-POP-${ko}-${s}.png`)}`, url('QR-POP-A5.html', `${k}/${s}`)]);
  console.log('POP', ko);
}
run([`--print-to-pdf=${path.join(pdfDir, 'QR모음-A4.pdf')}`, url('QR모음-A4.html', '')]);
for (const s of STORES)
  run(['--force-device-scale-factor=2', '--window-size=794,1123', `--screenshot=${path.join(pngDir, `QR모음-${s}.png`)}`, url('QR모음-A4.html', s)]);
console.log('QR모음 done');
