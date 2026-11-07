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
    .art{width:1200px;height:675px;position:relative;overflow:hidden;
      background:
        radial-gradient(680px 420px at 18% 22%, #9fe3c1 0%, transparent 62%),
        radial-gradient(720px 460px at 82% 18%, #f3c98b 0%, transparent 60%),
        radial-gradient(820px 520px at 60% 108%, #587da8 0%, transparent 64%),
        linear-gradient(160deg,#101b20 0%,#18302f 46%,#2a2130 100%);
      color:#f8f3e8;font-family:Georgia,serif}
    .grain{position:absolute;inset:0;opacity:.09;
      background-image:repeating-linear-gradient(0deg,#fff 0 1px,transparent 1px 3px)}
    .orb{position:absolute;width:340px;height:340px;border-radius:50%;
      left:120px;top:120px;background:radial-gradient(circle at 34% 30%,#fffdf6,transparent 22%),
      radial-gradient(circle,#ffd9a3 0%,#f09a6b 52%,#7c4a62 100%);
      box-shadow:0 40px 120px rgba(0,0,0,.55);filter:saturate(1.1)}
    .line{position:absolute;left:0;right:0;bottom:0;height:120px;
      background:linear-gradient(180deg,transparent,rgba(0,0,0,.45))}
    .copy{position:absolute;left:64px;bottom:56px;z-index:2}
    .eyebrow{font:700 13px/1 ui-sans-serif,system-ui;letter-spacing:.24em;text-transform:uppercase;color:#b9e6cf}
    h1{font-size:64px;line-height:1.02;margin:14px 0 0;letter-spacing:-.03em;max-width:12ch}
    p{font:16px/1.5 ui-sans-serif,system-ui;color:#cfd9d4;margin:14px 0 0}
  </style><div class="art"><div class="grain"></div><div class="orb"></div><div class="line"></div>
  <div class="copy"><div class="eyebrow">Field notes</div><h1>Light, weather, and open water.</h1>
  <p>A demo image uploaded through the file form, no JavaScript involved.</p></div></div>`);
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
  await page.waitForSelector('article.reader');
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
  await page.waitForSelector('article.reader');
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
  await page.waitForSelector('article.reader');
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
  await page.waitForSelector('text=Your draft (not saved)');
  await page.waitForTimeout(600);
  await shotFit(page, 'conflict.png');

  // 12. Restore the default theme for the next run.
  await page.goto(BASE + '/settings', { waitUntil: 'load' });
  await page.click('label.theme-card:has(input[value=feather])');
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
