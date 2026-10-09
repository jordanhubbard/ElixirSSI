import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
const [modules, prefix, output, manager] = process.argv.slice(2);
const require = createRequire(path.resolve(modules, 'package.json'));
const {chromium} = require('playwright-core');
const port = process.env.SSI_COMMAND_PORT || '4100';
const desktopPort = process.env.SSI_DESKTOP_PORT || '4110';
const rpc = source => execFileSync('docker', ['exec', manager, '/command/bin/ssi_command', 'rpc', source], {encoding:'utf8'}).trim();
const browser = await chromium.launch({headless:true, executablePath:process.env.SSI_CHROME || (process.platform === 'darwin' ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' : chromium.executablePath())});
try {
  const page = await browser.newPage({viewport:{width:1440,height:1000}});
  const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('dialog', d => d.accept());
  await page.goto(`http://localhost:${port}/`);
  if (!page.url().endsWith('/login')) throw new Error('Unauthenticated workspace was accessible');
  const ticket = rpc('IO.write(ElixirSSI.Command.Auth.ticket())');
  // Opening the launcher creates a new document; a hash-only navigation does not.
  await page.goto('about:blank');
  await page.goto(`http://localhost:${port}/login#ticket=${ticket}`);
  await page.waitForSelector('.phx-connected');
  const nav = async name => {await page.getByRole('button',{name,exact:true}).click(); await page.getByRole('heading',{name,exact:true}).waitFor();};
  const result = async label => {
    await nav('Operations'); const operation = page.locator('.operation').first();
    await operation.filter({hasText:label}).waitFor();
    await page.waitForFunction(() => /succeeded|failed/.test(document.querySelector('.operation h3')?.textContent || ''), null, {timeout:300000});
    const text = await operation.innerText();
    if (!text.includes('succeeded')) throw new Error(text);
    console.log('PASS:', label); return text;
  };
  await page.getByRole('button',{name:'Start',exact:true}).click(); await result('Instances: start');
  await nav('Cluster'); await page.getByText('Healthy',{exact:true}).first().waitFor();
  if (await page.locator('.member').count() !== 3) throw new Error('Expected three members');
  await nav('Console');
  await page.locator('#probe-ssh [name=host]').fill('host.docker.internal');
  await page.locator('#probe-ssh [name=port]').fill('2321');
  await page.getByRole('button',{name:'Inspect identity',exact:true}).click();
  await page.locator('#trust-ssh [name=password]').fill('elixir');
  await page.getByRole('button',{name:'Trust identity and connect',exact:true}).click();
  await page.locator('#remote-evaluate').waitFor();
  await nav('Projects'); await page.locator('#create-project [name=name]').fill('acceptance_app');
  await page.getByRole('button',{name:'Create project',exact:true}).click();
  const save = async (file, source) => {
    await page.locator('#source-editor [name=file]').fill(file);
    await page.locator('#source-editor [name=source]').fill(source);
    await page.getByRole('button',{name:'Save file',exact:true}).click();
    await page.getByText(`Saved ${file}.`,{exact:true}).waitFor();
  };
  await save('mix.exs', 'defmodule AcceptanceApp.MixProject do\n use Mix.Project\n def project, do: [app: :acceptance_app, version: "0.1.0", deps: [{:workbench_support, path: "vendor/workbench_support"}]]\n def application, do: [extra_applications: [:logger]]\nend\n');
  await save('vendor/workbench_support/mix.exs', 'defmodule WorkbenchSupport.MixProject do\n use Mix.Project\n def project, do: [app: :workbench_support, version: "0.1.0", deps: []]\n def application, do: [extra_applications: [:logger]]\nend\n');
  await save('vendor/workbench_support/lib/workbench_support.ex', 'defmodule WorkbenchSupport do\n def value, do: 42\nend\n');
  await save('lib/acceptance_app.ex', 'defmodule AcceptanceApp do\n def hello, do: :world\n def value, do: WorkbenchSupport.value()\n def resource, do: File.read!(Application.app_dir(:acceptance_app, "priv/value.txt"))\nend\n');
  await save('priv/value.txt', 'from the Phoenix editor');
  await page.getByRole('button',{name:'Test',exact:true}).click(); await result('acceptance_app: test');
  await nav('Projects'); await page.getByRole('button',{name:'acceptance_app',exact:true}).click();
  await page.getByRole('button',{name:'Deploy application',exact:true}).click(); await result('Deploy acceptance_app');
  const evaluate = async source => {
    await nav('Console'); await page.locator('#remote-evaluate [name=source]').fill(source);
    await page.getByRole('button',{name:'Run on node',exact:true}).click(); return result('Elixir on');
  };
  const check = async () => evaluate('unless AcceptanceApp.value() == 42 and AcceptanceApp.resource() == "from the Phoenix editor", do: raise("deployed application is incomplete"); :deployment_verified');
  await check();
  await nav('Desktop'); await page.locator('#desktop-connect [name=endpoint]').fill(`host.docker.internal:${desktopPort}`);
  await page.getByRole('button',{name:'Connect desktop',exact:true}).click();
  await page.waitForFunction(() => document.querySelector('.desktop-status')?.textContent.startsWith('Connected'), null, {timeout:60000});
  const canvas = page.locator('#desktop-view canvas'); await canvas.scrollIntoViewIfNeeded(); const box = await canvas.boundingBox();
  await page.mouse.click(box.x + 835 * box.width / 1280, box.y + 778 * box.height / 800);
  await page.waitForTimeout(500); await page.keyboard.type('40 + 2'); await page.keyboard.press('Enter');
  await page.waitForTimeout(1000);
  const shell = await evaluate('s = SSI.Desktop.app_state(SSI.Desktop.ShellApp); unless "40 + 2" in s.history and Enum.any?(s.lines, &String.contains?(&1, "42")), do: raise("browser input did not reach the guest shell"); :desktop_input_verified');
  if (!shell.includes('desktop_input_verified')) throw new Error('Missing desktop result');
  await nav('Desktop'); await page.waitForFunction(() => document.querySelector('.desktop-status')?.textContent.startsWith('Connected'));
  await page.screenshot({path:path.join(output,'installed-workspace.png'),fullPage:true});
  await nav('Cluster'); await page.getByRole('button',{name:'Restart',exact:true}).click(); await result('Instances: restart');
  try {await check();} catch (error) {
    // Diagnose readiness versus identity drift without exposing credentials.
    await page.waitForTimeout(5000);
    console.error(rpc('saved = File.read!(Path.join(ElixirSSI.Command.Store.directory(), "ssh-credentials.json")) |> Jason.decode!(); case ElixirSSI.Command.Remote.probe("host.docker.internal", 2321) do {:ok, fingerprint} -> IO.inspect({:restart_identity_matches, fingerprint == saved["host.docker.internal|2321"]["fingerprint"]}); other -> IO.inspect(other) end; IO.inspect(ElixirSSI.Command.Remote.evaluate("host.docker.internal|2321", ":restart_ssh_ready"))'));
    throw error;
  }
  await nav('Cluster'); await page.locator('#physical-node [name=endpoint]').fill('http://127.0.0.1:9');
  await page.getByRole('button',{name:'Connect Pi',exact:true}).click();
  const physical = page.locator('.member').filter({hasText:'http://127.0.0.1:9'}); await physical.waitFor();
  await physical.getByRole('button',{name:'Remove Pi',exact:true}).click(); await physical.waitFor({state:'detached'});
  await page.setViewportSize({width:390,height:844});
  if (await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)) throw new Error('Mobile overflow');
  await page.getByRole('button',{name:'Stop',exact:true}).click(); await result('Instances: stop');
  await page.reload(); await page.waitForSelector('.phx-connected');
  await nav('Projects'); await page.getByRole('button',{name:'acceptance_app',exact:true}).waitFor();
  if (errors.length) throw new Error(errors.join('\n'));
  console.log('PASS: packaged Phoenix lifecycle, IDE, deployment, desktop, persistence and offline workspace');
} finally {await browser.close();}
