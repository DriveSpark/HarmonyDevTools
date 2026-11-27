const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));

function runtime() {
  let disk = '';
  let cache = '';
  let fail = false;
  const watchers = new Set();
  const preferences = { getPreferencesSync: () => ({
    getSync: () => disk, putSync: (_, value) => { cache = value; },
    flushSync: () => { if (fail) { throw Error('disk full'); } disk = cache; }
  }) };
  const hiAppEvent = {
    domain: { OS: 'OS' }, event: { APP_CRASH: 'APP_CRASH' },
    addWatcher: watcher => watchers.add(watcher), removeWatcher: watcher => watchers.delete(watcher)
  };
  const mod = {};
  const text = fs.readFileSync(path.join(__dirname, '../devtools/src/main/ets/DevToolsCrashStore.ets'), 'utf8');
  const js = ts.transpileModule(text, { compilerOptions: { target: ts.ScriptTarget.ES2021,
    module: ts.ModuleKind.CommonJS, experimentalDecorators: true } }).outputText;
  new Function('require', 'exports', 'Trace', 'ObservedV2', js)(
    () => ({ preferences, hiAppEvent }), mod, () => {}, type => type);
  const connect = () => {
    const s = new mod.DevToolsCrashStore();
    s.attach({ applicationInfo: { name: 'org.example.demo' } });
    return s;
  };
  const deliver = (w, events) => w.onReceive('OS', [{ name: 'APP_CRASH',
    appEventInfos: events.map(params => ({ name: 'APP_CRASH', domain: 'OS', params })) }]);
  return { watchers, connect, deliver, setFail: value => { fail = value; } };
}

test('opt-in persists, scopes by package/time, and an old callback cannot repopulate cleared history', () => {
  const r = runtime(), s = r.connect();
  assert.equal(r.watchers.size, 0);
  s.setEnabled(true);
  const [w] = r.watchers;
  const t = Date.now() + 1;
  const event = { time: t, pid: 18, bundle_name: 'org.example.demo', crash_type: 'JsError',
    exception: { name: 'Error', message: 'fixture failure', stack: 'at sample.ets:10' } };
  r.deliver(w, [event, event, { ...event, pid: 19, bundle_name: 'org.example.demo.extra' },
    { ...event, time: t - 500000 }]);
  assert.equal(s.records.length, 1);
  assert.equal(s.records[0].reason, 'fixture failure');
  assert.match(s.records[0].stack, /sample.ets/);
  s.detach();
  const reopened = r.connect();
  assert.equal(reopened.enabled, true);
  assert.equal(reopened.records.length, 1);
  reopened.clear();
  r.deliver(w, [event]);
  assert.equal(reopened.records.length, 0);
  reopened.setEnabled(false);
  reopened.detach();
  assert.equal(r.connect().enabled, false);
  assert.equal(r.watchers.size, 0);
});

test('native frames remain readable and a failed clear leaves saved records intact', () => {
  const r = runtime(), s = r.connect();
  s.setEnabled(true);
  r.deliver([...r.watchers][0], [{ time: Date.now(), pid: 999, bundle_name: 'org.example.demo',
    crash_type: 'NativeCrash', exception: { message: 'signal', frames: [
      { pc: '044', file: 'libexample.so', symbol: 'main' }] } }]);
  assert.match(s.records[0].stack, /libexample\.so.*main/);
  r.setFail(true);
  s.clear();
  assert.equal(s.records.length, 1);
  assert.ok(s.error);
});

test('a native report with an empty message preserves the system signal as its reason', () => {
  const r = runtime(), s = r.connect();
  s.setEnabled(true);
  r.deliver([...r.watchers][0], [{ time: Date.now(), pid: 123, bundle_name: 'org.example.demo',
    crash_type: 'NativeCrash', exception: { message: '', signal: { signo: 6, code: -6 } } }]);
  assert.match(s.records[0].reason, /SIGABRT/);
  assert.match(s.records[0].reason, /code -6/);
});
