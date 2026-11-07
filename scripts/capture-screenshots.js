// Capture the README screenshots from a running demo instance.
//
//   FEATHERNOTE_URL=http://127.0.0.1:8090 \
//   FEATHERNOTE_PASSWORD='...' \
//   NODE_PATH=/path/to/node_modules node scripts/capture-screenshots.js
//
// Requires Playwright with Chromium installed. Writes docs/screenshots/*.png.
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const BASE = process.env.FEATHERNOTE_URL || 'http://127.0.0.1:8090';
const PASSWORD = process.env.FEATHERNOTE_PASSWORD || 'correct horse battery staple';
const OUT = path.join(process.cwd(), 'docs', 'screenshots');
fs.mkdirSync(OUT, { recursive: true });

async function shot(page, name, opts = {}) {
  await page.screenshot({ path: path.join(OUT, name), animations: 'disabled', ...opts });
  console.log('captured', name);
}

// Resize the viewport to the full content height, so short pages are not mostly
// blank and tall pages are not clipped.
async function shotFit(page, name) {
  const { width } = page.viewportSize();
  // Measure against a small viewport; scrollHeight never shrinks below it.
  await page.setViewportSize({ width, height: 360 });
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  await page.setViewportSize({ width, height: Math.min(Math.max(height, 360), 6000) });
  await page.evaluate(() => window.scrollTo(0, 0));
  await shot(page, name);
}

(async () => {
  const browser = await chromium.launch();

  const desktop = await browser.newContext({
    viewport: { width: 1280, height: 820 },
    deviceScaleFactor: 2,
    colorScheme: 'light',
  });
  const page = await desktop.newPage();

  // 1. Login
  await page.goto(BASE + '/login', { waitUntil: 'networkidle' });
  await shotFit(page, 'login.png');
  await page.fill('#password', PASSWORD);

  await page.click('button[type=submit]');
  await page.waitForURL('**/notes');

  // 2. Notes list
  await shotFit(page, 'notes-list.png');

  // 3. Note editor
  await page.click('text=Zig 0.17 async I/O notes');
  await page.waitForSelector('#body');
  await shotFit(page, 'note-editor.png');

  // 4. Search
  await page.goto(BASE + '/notes?q=book', { waitUntil: 'networkidle' });
  await shotFit(page, 'search.png');

  // 5. Trash
  await page.goto(BASE + '/trash', { waitUntil: 'networkidle' });
  await shotFit(page, 'trash.png');

  // 6. New note composer
  await page.goto(BASE + '/notes/new', { waitUntil: 'networkidle' });
  await page.fill('#title', 'Untitled thought');
  await page.fill('#body', 'Paste the thing here, then sort it out later.');
  await shotFit(page, 'new-note.png');

  // 7. Edit conflict: change the note from a second request while the
  //    editor still holds the old version, then submit the stale form.
  await page.goto(BASE + '/notes', { waitUntil: 'networkidle' });
  await page.click('text=Trip to Lisbon');
  await page.waitForSelector('#body');
  const noteUrl = page.url();
  const noteId = noteUrl.split('/').pop();
  const csrf = await page.inputValue('input[name=csrf]');
  const version = await page.inputValue('input[name=version]');
  await page.request.post(BASE + '/notes/' + noteId, {
    form: {
      csrf,
      version,
      title: 'Trip to Lisbon',
      body: 'Flights booked, 14-21 March.\n\nUpdated from another tab: the Sintra day trip moved to the 16th.',
    },
  });
  await page.fill('#body', 'Flights booked, 14-21 March.\n\nPlanning notes from this tab, which is now stale.');
  await page.click('.editor-form button[type=submit]');
  await page.waitForSelector('text=Your draft (not saved)');
  await shotFit(page, 'conflict.png');

  await desktop.close();

  // 8. Mobile list
  const mobile = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    colorScheme: 'light',
  });
  const mpage = await mobile.newPage();
  await mpage.goto(BASE + '/login', { waitUntil: 'networkidle' });
  await mpage.fill('#password', PASSWORD);
  await mpage.click('button[type=submit]');
  await mpage.waitForURL('**/notes');
  await shotFit(mpage, 'mobile-notes.png');
  await mobile.close();

  await browser.close();
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
