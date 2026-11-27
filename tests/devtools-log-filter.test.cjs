const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
require('./register.cjs');

const sourceDir = path.join(__dirname, '../devtools/src/main/ets');
const { filterDevToolsLogs, devToolsLogProcesses, formatDevToolsLogTime } = require(
  path.join(sourceDir, 'DevToolsLogFilter.ets'));
const bundleName = 'cn.example.gov';
const timestamp = new Date(2026, 10, 27, 9, 8, 7, 6).getTime();
function entry(id, pid, level, tag, message, bundle = bundleName, process = bundle) {
  return { id, pid, level, tag, message, bundleName: bundle, processName: process, time: timestamp };
}
const records = [
  entry('1', 42, 3, 'Camera', 'preview ready'),
  entry('2', 420, 4, 'Camera PIPE', 'capture START', bundleName, 'photo_worker'),
  entry('3', 42, 5, 'Upload', 'camera retry\n详细内容'),
  entry('4', 7, 6, 'Camera PIPE', 'capture failed', bundleName + '.other', bundleName),
  entry('5', 420, 7, 'Video', 'capture failed', bundleName, 'photo_worker'),
  entry('6', 9, 6, 'Unknown', 'no bundle', '', bundleName)
];
function matches(options) {
  return filterDevToolsLogs(records, { bundleName, ...options }).map(item => item.id);
}

test('current app defaults to exact claimed bundle, retaining all its processes and source order', () => {
  assert.deepEqual(matches({}), ['1', '2', '3', '5']);
  assert.deepEqual(matches({ onlyCurrentApp: false }), ['1', '2', '3', '4', '5', '6']);
  assert.deepEqual(matches({ bundleName: '' }), []);
  assert.equal(records.length, 6);
});

test('levels are minimum thresholds, even when a higher level is not present in the selected process', () => {
  assert.deepEqual(matches({ minimumLevel: 5 }), ['3', '5']);
  assert.deepEqual(matches({ minimumLevel: 7 }), ['5']);
  assert.deepEqual(matches({ minimumLevel: 4, pid: 42 }), ['3']);
  assert.deepEqual(matches({ minimumLevel: 6, pid: 42 }), []);
});

test('plain text matches full messages or tags without case sensitivity and numeric PID by equality', () => {
  assert.deepEqual(matches({ keyword: ' camera ' }), ['1', '2', '3']);
  assert.deepEqual(matches({ keyword: '详细' }), ['3']);
  assert.deepEqual(matches({ keyword: '42' }), ['1', '3']);
  assert.deepEqual(matches({ keyword: '420' }), ['2', '5']);
  assert.deepEqual(matches({ keyword: 'photo_worker' }), []);
});

test('DoKit pid and quoted tag predicates also combine with free text and the selected process', () => {
  assert.deepEqual(matches({ keyword: 'PID:420 tag:"camera pipe"  START' }), ['2']);
  assert.deepEqual(matches({ keyword: 'tag:CAMERA pid:42' }), ['1']);
  assert.deepEqual(matches({ keyword: 'pid:7', pid: 42, onlyCurrentApp: false }), []);
});

test('process choices use source metadata and exact bundle scope, with one option per numeric PID', () => {
  assert.deepEqual(devToolsLogProcesses(records, bundleName, true), [
    { pid: 42, name: bundleName }, { pid: 420, name: 'photo_worker' }
  ]);
  assert.deepEqual(devToolsLogProcesses(records, bundleName, false).map(item => item.pid), [7, 9, 42, 420]);
});

function exporter(pickerUris, write) {
  const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
    'tools/hvigor/hvigor/node_modules/typescript'));
  const filename = path.join(sourceDir, 'DevToolsLogExport.ets');
  const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText;
  const calls = [];
  const fakeFile = { fd: 7 };
  const kits = {
    '@kit.CoreFileKit': {
      picker: { DocumentViewPicker: class { async save(options) { calls.push(options); return pickerUris; } } },
      fileIo: {
        OpenMode: { WRITE_ONLY: 1, TRUNC: 512 },
        async open(uri, mode) { calls.push(['open', uri, mode]); return fakeFile; },
        async write(fd, bytes) { assert.equal(fd, 7); return write(new Uint8Array(bytes)); },
        async fsync(fd) { calls.push(['fsync', fd]); },
        async close(fd) { calls.push(['close', fd]); }
      }
    },
    '@kit.ArkTS': { util: { TextEncoder: { create: () => ({ encodeInto: text => new TextEncoder().encode(text) }) } } },
    './DevToolsLogFilter': require(path.join(sourceDir, 'DevToolsLogFilter.ets'))
  };
  const compiled = {};
  new Function('require', 'exports', source)(name => kits[name], compiled);
  return { save: list => compiled.saveDevToolsLogFile({}, list), calls };
}

test('export preserves metadata, multiline Unicode and all records after short writes', async () => {
  const chunks = [];
  const { save, calls } = exporter(['file://docs/export.log'], bytes => {
    const length = Math.min(17, bytes.byteLength);
    chunks.push(Buffer.from(bytes.subarray(0, length)));
    return length;
  });
  assert.equal(await save(records), 'saved');
  const text = Buffer.concat(chunks).toString('utf8');
  assert.equal(formatDevToolsLogTime(timestamp), '2026-11-27 09:08:07.006');
  assert.match(text, /2026-11-27 09:08:07\.006/);
  assert.match(text, /420.*photo_worker.*I.*Camera PIPE.*capture START/);
  assert.match(text, /camera retry\n详细内容/);
  assert.ok(text.includes(bundleName + '.other'));
  assert.ok(text.includes('no bundle'));
  assert.deepEqual(calls.slice(1), [['open', 'file://docs/export.log', 513], ['fsync', 7], ['close', 7]]);
});

test('cancelling export makes no file and an incomplete write closes the descriptor without reporting success', async () => {
  const canceled = exporter([], () => { throw new Error('unexpected write'); });
  assert.equal(await canceled.save(records), 'canceled');
  assert.equal(canceled.calls.length, 1);
  const failed = exporter(['file://docs/export.log'], () => 0);
  assert.equal(await failed.save(records), 'failed');
  assert.deepEqual(failed.calls.slice(1), [['open', 'file://docs/export.log', 513], ['close', 7]]);
});
