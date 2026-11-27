const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));

const filename = path.join(__dirname, '../devtools/src/main/ets/DevToolsPerformance.ets');
const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function createMonitor(t, cpu = () => 0.25, memory = async () => ({ pss: 1536n })) {
  t.mock.timers.enable({ apis: ['Date', 'setTimeout'] });
  const calls = { cpu: 0, memory: 0 };
  const pending = new Set();
  function schedule(callback, delay) {
    const timer = setTimeout(() => { pending.delete(timer); callback(); }, delay);
    pending.add(timer);
    return timer;
  }
  function cancel(timer) {
    pending.delete(timer);
    clearTimeout(timer);
  }
  const kits = {
    '@kit.ArkTS': { taskpool: { execute: async operation => operation() } },
    '@kit.PerformanceAnalysisKit': { hidebug: {
      getCpuUsage() { calls.cpu++; return cpu(); },
      getAppNativeMemInfoAsync() { calls.memory++; return memory(); }
    } }
  };
  const compiled = {};
  new Function('require', 'exports', 'setTimeout', 'clearTimeout', source)(name => kits[name], compiled, schedule, cancel);
  const monitor = new compiled.DevToolsPerformance();
  t.after(() => monitor.dispose());
  async function tick(milliseconds) {
    t.mock.timers.tick(milliseconds);
    await new Promise(resolve => setImmediate(resolve));
  }
  return { monitor, calls, tick, pending };
}

test('sampling follows the individual switches at 500 ms and only while the host is in the foreground', async t => {
  const { monitor, calls, tick, pending } = createMonitor(t, () => 0);
  assert.equal(monitor.isEnabled('cpu'), false);
  assert.equal(monitor.latest('cpu'), undefined);
  monitor.setEnabled('cpu', true);
  assert.equal(pending.size, 0);
  await tick(1000);
  assert.deepEqual(calls, { cpu: 0, memory: 0 });

  monitor.setForeground(true);
  monitor.setForeground(true);
  monitor.setEnabled('cpu', true);
  await tick(499);
  assert.equal(calls.cpu, 0);
  await tick(1);
  assert.deepEqual(monitor.latest('cpu'), { timestamp: 1500, value: 0 });
  assert.deepEqual(calls, { cpu: 1, memory: 0 });

  monitor.setEnabled('memory', true);
  await tick(500);
  assert.deepEqual(calls, { cpu: 2, memory: 1 });
  assert.equal(monitor.latest('memory').value, 1.5);
  monitor.setEnabled('cpu', false);
  await tick(500);
  assert.deepEqual(calls, { cpu: 2, memory: 2 });
  assert.equal(monitor.history('cpu').length, 2);

  monitor.setForeground(false);
  assert.equal(pending.size, 0);
  await tick(10000);
  assert.deepEqual(calls, { cpu: 2, memory: 2 });
  assert.equal(monitor.isEnabled('memory'), true);
  monitor.setForeground(true);
  await tick(500);
  assert.deepEqual(calls, { cpu: 2, memory: 3 });
});

test('a slow read cannot overlap or publish into a new monitoring period', async t => {
  let finishCpu;
  const { monitor, calls, tick, pending } = createMonitor(t, () => new Promise(resolve => { finishCpu = resolve; }));
  monitor.setForeground(true);
  monitor.setEnabled('cpu', true);
  await tick(500);
  monitor.setEnabled('cpu', false);
  monitor.setEnabled('cpu', true);
  await tick(5000);
  assert.equal(calls.cpu, 1);
  assert.equal(pending.size, 0);
  finishCpu(0.75);
  await tick(0);
  assert.deepEqual(monitor.history('cpu'), []);

  await tick(500);
  assert.equal(calls.cpu, 2);
  finishCpu(0.25);
  await tick(0);
  assert.equal(monitor.latest('cpu').value, 25);
  assert.equal(monitor.history('cpu').length, 1);
});

test('a hidden or disposed host ignores late readings and a disposed host cannot restart', async t => {
  let finishMemory;
  const { monitor, calls, tick } = createMonitor(t, undefined,
    () => new Promise(resolve => { finishMemory = resolve; }));
  monitor.setForeground(true);
  monitor.setEnabled('memory', true);
  let changes = 0;
  monitor.subscribe(() => { changes++; });
  await tick(500);
  monitor.setForeground(false);
  monitor.setForeground(true);
  finishMemory({ pss: 1536n });
  await tick(0);
  assert.equal(monitor.latest('memory'), undefined);
  await tick(500);
  monitor.dispose();
  finishMemory({ pss: 2048n });
  await tick(0);
  monitor.setForeground(true);
  monitor.setEnabled('cpu', true);
  await tick(5000);
  assert.deepEqual(calls, { cpu: 0, memory: 2 });
  assert.equal(monitor.isEnabled('memory'), false);
  assert.equal(monitor.latest('memory'), undefined);
  assert.equal(changes, 0);
});

test('a failed SDK reading is distinct from zero and other metrics keep updating', async t => {
  const cpuReadings = [NaN, -1, 0.125];
  let memoryAvailable = false;
  const { monitor, tick } = createMonitor(t, () => cpuReadings.shift(), async () => {
    if (!memoryAvailable) { throw new Error('unavailable'); }
    return { pss: 2048n };
  });
  monitor.setForeground(true);
  monitor.setEnabled('cpu', true);
  monitor.setEnabled('memory', true);
  await tick(500);
  assert.deepEqual(monitor.latest('cpu'), { timestamp: 500, value: undefined });
  assert.deepEqual(monitor.latest('memory'), { timestamp: 500, value: undefined });
  memoryAvailable = true;
  await tick(500);
  assert.equal(monitor.latest('cpu').value, undefined);
  assert.equal(monitor.latest('memory').value, 2);
  await tick(500);
  assert.equal(monitor.latest('cpu').value, 12.5);
});

test('a reopened view can read recent records after stopping and unsubscribe without stopping sampling', async t => {
  const { monitor, calls, tick, pending } = createMonitor(t);
  monitor.setForeground(true);
  monitor.setEnabled('cpu', true);
  let viewsUpdated = 0;
  const closeView = monitor.subscribe(() => { viewsUpdated++; });
  await tick(500);
  assert.equal(viewsUpdated, 1);
  closeView();
  for (let count = 0; count < 120; count++) { await tick(500); }
  monitor.setEnabled('cpu', false);
  assert.equal(pending.size, 0);
  await tick(10000);
  assert.equal(calls.cpu, 121);
  assert.equal(viewsUpdated, 1);
  const history = monitor.history('cpu');
  assert.equal(history.length, 120);
  assert.deepEqual(history[0], { timestamp: 1000, value: 25 });
  assert.deepEqual(history.pop(), { timestamp: 60500, value: 25 });
  assert.equal(monitor.history('cpu').length, 120);
  assert.equal(monitor.latest('cpu').timestamp, 60500);
});
