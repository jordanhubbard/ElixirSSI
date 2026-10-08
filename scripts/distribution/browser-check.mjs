import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
const [modules, prefix, evidence, python] = process.argv.slice(2);
const require = createRequire(path.resolve(modules, 'package.json'));
const {chromium} = require('playwright-core');
const browser = await chromium.launch({headless:true, executablePath:process.env.SSI_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.goto(pathToFileURL(path.join(prefix,'monitor.html')).href + '#endpoints=localhost:8181,localhost:8182,localhost:8183');
  await page.waitForFunction(() => document.querySelector('#verdict').textContent === 'Healthy', null, {timeout:60000});
  const count = await page.locator('#member-cards > *').count();
  if (count !== 3) throw new Error(`Expected three member cards; saw ${count}`);
  await page.screenshot({path:path.join(evidence,'installed-monitor.png'),fullPage:true});
  execFileSync(python, [path.join(prefix,'elixirssi'),'stop']);
  await page.waitForFunction(() => document.querySelector('#verdict').textContent === 'Down', null, {timeout:30000});
  await page.reload();
  await page.waitForFunction(() => document.querySelector('#verdict').textContent === 'Down', null, {timeout:30000});
  if (await page.locator('#member-cards > *').count() !== 3) throw new Error('Offline monitor lost its remembered members');
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('PASS: browser renders Healthy, then Down with all three members remembered after reload');
} finally { await browser.close(); }
