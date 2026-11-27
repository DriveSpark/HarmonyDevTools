const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));
const filename = path.join(__dirname, '../devtools/src/main/ets/DevToolsLogSource.ets');
const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
}).outputText;
const app = { cacheDir: '/app/cache', applicationInfo: { name: 'org.example.host' }, processName: 'org.example.host:aux' };
const context = { getApplicationContext: () => app };

function logSource(native) {
  const compiled = {};
  new Function('require', 'exports', source)(name => {
    assert.equal(name, 'libdevtools_hilog.so');
    return native;
  }, compiled);
  return new compiled.DevToolsLogSource();
}
function row(id, time) {
  return { id: String(id), time, bundleName: app.applicationInfo.name, processName: app.processName,
    pid: 350, level: 4, tag: 'TestTag', message: 'line ' + id };
}

test('source opts in once, forwards real application context fields and releases exactly once', () => {
  const calls = [];
  const capture = logSource({
    acquire(...args) { calls.push(args); },
    release() { calls.push('release'); }
  });
  assert.equal(capture.active, false);
  assert.deepEqual(capture.snapshot(), []);
  capture.start(context);
  capture.start(context);
  assert.deepEqual(calls, [[app.cacheDir, app.applicationInfo.name, app.processName]]);
  assert.equal(capture.bundleName, app.applicationInfo.name);
  capture.dispose();
  capture.dispose();
  assert.equal(capture.active, false);
  assert.deepEqual(calls, [[app.cacheDir, app.applicationInfo.name, app.processName], 'release']);
});

test('source merges delayed PIDs by capture time, handles remote clear/wrap and requests only unread IDs', () => {
  const requests = [];
  const updates = [
    { first: 1, latest: 2, entries: [row(1, 250), row(2, 100)] },
    { first: 2, latest: 3, entries: [row(3, 200)] },
    { first: 4, latest: 3, entries: [] }
  ];
  const capture = logSource({
    acquire() {},
    readSince(after) { requests.push(after); return updates.shift(); },
    release() {}
  });
  capture.start(context);
  assert.deepEqual(capture.snapshot().map(entry => entry.id), ['2', '1']);
  assert.deepEqual(capture.snapshot().map(entry => entry.id), ['2', '3']);
  assert.deepEqual(capture.snapshot(), []);
  assert.deepEqual(requests, [0, 2, 3]);
  capture.dispose();
});

test('setup and I/O failures are visible and a failed clear keeps previously captured records', () => {
  let first = true;
  let canRead = true;
  const capture = logSource({
    acquire() { if (first) { first = false; throw Error(); } },
    readSince() {
      if (!canRead) { throw Error(); }
      return { first: 1, latest: 1, writeFailed: true, entries: [row(1, 300)] };
    },
    clear() { throw Error(); },
    release() {}
  });
  capture.start(context);
  assert.equal(capture.active, false);
  assert.match(capture.error, /启用/);
  capture.start(context);
  assert.equal(capture.active, true);
  assert.equal(capture.snapshot().length, 1);
  assert.match(capture.error, /部分/);
  capture.clear();
  assert.match(capture.error, /清空/);
  canRead = false;
  assert.deepEqual(capture.snapshot().map(entry => entry.id), ['1']);
  assert.match(capture.error, /读取/);
  capture.dispose();
});
