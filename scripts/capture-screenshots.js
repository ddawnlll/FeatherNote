// Capture the README screenshots from a running demo instance.
//
//   FEATHERNOTE_URL=http://127.0.0.1:8090 \
//   FEATHERNOTE_PASSWORD='...' \
//   npm run --silent screenshots
//
// Requires Playwright with Chromium installed. Writes docs/screenshots/*.png.
// The browser context has JavaScript disabled, which is also how the app is
// meant to be used.
const { chromium } = require('playwright');
const fs = require('fs');
const os = require('os');
const path = require('path');

const BASE = process.env.FEATHERNOTE_URL || 'http://127.0.0.1:8090';
const PASSWORD = process.env.FEATHERNOTE_PASSWORD || 'correct horse battery staple';
const OUT = path.join(process.cwd(), 'docs', 'screenshots');
fs.mkdirSync(OUT, { recursive: true });

async function shot(page, name, opts = {}) {
  await page.screenshot({ path: path.join(OUT, name), animations: 'disabled', ...opts });
  console.log('captured', name);
}

// Resize the viewport to the full content height so short pages are not mostly
// blank and tall pages are not clipped.
async function shotFit(page, name) {
  const { width } = page.viewportSize();
  await page.setViewportSize({ width, height: 360 });
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  await page.setViewportSize({ width, height: Math.min(Math.max(height, 360), 8000) });
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(250);
  await shot(page, name);
}

async function login(page) {
  await page.goto(BASE + '/login', { waitUntil: 'load' });
  await page.fill('#password', PASSWORD);
  await page.click('button[type=submit]');
  await page.waitForURL('**/notes');
}

async function makeDemoImage(browser) {
  const file = path.join(os.tmpdir(), 'feathernote-demo-aurora.png');
  const page = await browser.newPage({ viewport: { width: 1200, height: 675 } });
  await page.setContent(`<!doctype html><style>
    html,body{margin:0;height:100%}
    .art{width:1200px;height:675px;position:relative;overflow:hidden;background:#14211f;color:#efe9dc;
      font-family:"Iowan Old Style",Palatino,Georgia,serif}
    .sky{position:absolute;inset:0 0 46% 0;background:#1c3330}
    .sea{position:absolute;inset:54% 0 22% 0;background:#274b45}
    .shore{position:absolute;inset:78% 0 0 0;background:#c9b79a}
    .rule{position:absolute;left:72px;right:72px;top:72px;height:1px;background:#efe9dc;opacity:.5}
    .rule2{position:absolute;left:72px;right:72px;bottom:72px;height:1px;background:#efe9dc;opacity:.35}
    .mark{position:absolute;right:72px;top:64px;width:14px;height:14px;background:#b4372a}
    .copy{position:absolute;left:72px;bottom:230px}
    .kicker{font:700 12px/1 "Avenir Next",Avenir,sans-serif;letter-spacing:.22em;text-transform:uppercase;color:#c9b79a}
    h1{font-size:64px;line-height:.98;margin:18px 0 0;letter-spacing:-.02em;max-width:11ch}
    p{font:15px/1.5 "Avenir Next",Avenir,sans-serif;color:#cfd6cd;margin:18px 0 0;max-width:42ch}
    .coord{position:absolute;right:72px;bottom:230px;text-align:right;
      font:400 13px/1.6 "SF Mono",Menlo,monospace;color:#c9b79a}
  </style><div class="art"><div class="sky"></div><div class="sea"></div><div class="shore"></div>
  <div class="rule"></div><div class="rule2"></div><div class="mark"></div>
  <div class="copy"><div class="kicker">Field notes / 07</div><h1>North water, low light.</h1>
  <p>An upload from the file form. No scripts, no tracking, no external assets.</p></div>
  <div class="coord">61.2181 N<br>149.9003 W<br>07:40</div></div>`);
  await page.screenshot({ path: file, clip: { x: 0, y: 0, width: 1200, height: 675 } });
  await page.close();
  return file;
}

(async () => {
  const browser = await chromium.launch();

  const context = await browser.newContext({
    viewport: { width: 1280, height: 900 },
    deviceScaleFactor: 2,
    colorScheme: 'light',
    javaScriptEnabled: false,
  });
  const page = await context.newPage();

  // 1. Login
  await page.goto(BASE + '/login', { waitUntil: 'load' });
  await shotFit(page, 'login.png');
  await page.fill('#password', PASSWORD);
  await page.click('button[type=submit]');
  await page.waitForURL('**/notes');

  // 2. Light notes list
  await page.waitForTimeout(900);
  await shotFit(page, 'notes-list.png');

  // 3. Read view with Markdown
  await page.click('text=Zig 0.17 async I/O notes');
  await page.waitForSelector('.prose');
  await page.waitForTimeout(900);
  await shotFit(page, 'note-read.png');

  // 4. Editor
  await page.click('a.tab:has-text("Edit")');
  await page.waitForSelector('#body');
  await page.waitForTimeout(900);
  await shotFit(page, 'note-editor.png');

  // 5. Upload a generated image, then show the note with the image.
  const image = await makeDemoImage(browser);
  await page.setInputFiles('#file', {
    name: 'light-weather-water.png',
    mimeType: 'image/png',
    buffer: fs.readFileSync(image),
  });
  await page.click('.upload button[type=submit]');
  await page.waitForURL('**/edit?uploaded=1');
  await page.waitForTimeout(900);
  await page.click('a.tab:has-text("Read")');
  await page.waitForSelector('.prose');
  await page.waitForTimeout(900);
  await shotFit(page, 'note-with-image.png');

  // 6. Search
  await page.goto(BASE + '/notes?q=book', { waitUntil: 'load' });
  await page.waitForTimeout(700);
  await shotFit(page, 'search.png');

  // 7. Trash
  await page.goto(BASE + '/trash', { waitUntil: 'load' });
  await page.waitForTimeout(700);
  await shotFit(page, 'trash.png');

  // 8. New note composer
  await page.goto(BASE + '/notes/new', { waitUntil: 'load' });
  await page.fill('#title', 'Untitled thought');
  await page.fill('#body', '# A thought\n\nPaste the thing here, then sort it out later.');
  await page.waitForTimeout(400);
  await shotFit(page, 'new-note.png');

  // 9. Theme picker
  await page.goto(BASE + '/settings', { waitUntil: 'load' });
  await page.waitForTimeout(900);
  await shotFit(page, 'themes.png');

  // 10. Dark notes list
  await page.click('label.theme-card:has(input[value=midnight])');
  await page.click('form.theme-form button[type=submit]');
  await page.waitForURL('**/settings?saved=1');
  await page.goto(BASE + '/notes', { waitUntil: 'load' });
  await page.waitForTimeout(900);
  await shotFit(page, 'notes-dark.png');

  // 11. Edit conflict, while in the dark theme.
  await page.click('text=Trip to Lisbon');
  await page.waitForSelector('.prose');
  await page.click('a.tab:has-text("Edit")');
  await page.waitForSelector('#body');
  const noteUrl = page.url().replace('/edit', '');
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
  await page.waitForSelector('.diff-grid');
  await page.waitForTimeout(600);
  await shotFit(page, 'conflict.png');

  // 12. Restore the default theme for the next run.
  await page.goto(BASE + '/settings', { waitUntil: 'load' });
  await page.click('label.theme-card:has(input[value=paper])');
  await page.click('form.theme-form button[type=submit]');
  await page.waitForURL('**/settings?saved=1');

  await context.close();

  // 13. Mobile
  const mobile = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true,
    colorScheme: 'light',
    javaScriptEnabled: false,
  });
  const mpage = await mobile.newPage();
  await login(mpage);
  await mpage.waitForTimeout(900);
  await shotFit(mpage, 'mobile-notes.png');
  await mobile.close();

  await browser.close();
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
