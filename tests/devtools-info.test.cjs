const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));

const filename = path.join(__dirname, '../devtools/src/main/ets/DevToolsInfo.ets');
const source = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText;

function loadInfo(bundle, overrides = {}) {
  const kits = {
    '@kit.AbilityKit': { bundleManager: { BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 }, getBundleInfoForSelf: bundle } },
    '@kit.BasicServicesKit': { deviceInfo: { productModel: 'Phone', osFullName: 'OS', sdkApiVersion: 20 } },
    ...overrides
  };
  const compiled = {};
  new Function('require', 'exports', source)(name => kits[name], compiled);
  return compiled;
}

function createSession(bundle) {
  const { DevToolsInfoSession } = loadInfo(bundle);
  return new DevToolsInfoSession();
}

test('disposing an open panel discards its pending bundle read', async () => {
  let finishBundle;
  const session = createSession(() => new Promise(resolve => { finishBundle = resolve; }));
  const results = [];
  const pending = session.loadBasic(info => results.push(info));
  session.dispose();
  finishBundle({ name: 'example.app', versionName: '1', versionCode: 1 });
  await pending;
  assert.deepEqual(results, []);
});

test('device information is available when the bundle service fails', async () => {
  const session = createSession(async () => { throw new Error('unavailable'); });
  let basic;
  await session.loadBasic(info => { basic = info; });
  assert.equal(basic.deviceModel, 'Phone');
  assert.equal(basic.packageName, undefined);
});

test('uses the device ABI list and converts system MemTotal from KiB to GiB', async () => {
  const { DevToolsInfoSession } = loadInfo(async () => ({}), {
    '@kit.BasicServicesKit': { deviceInfo: { abiList: 'arm64-v8a,armeabi-v7a', sdkApiVersion: 20 } },
    '@kit.PerformanceAnalysisKit': { hidebug: { getSystemMemInfo: () => ({ totalMem: 8388608n }) } }
  });
  const session = new DevToolsInfoSession();
  let result;
  await session.loadBasic(info => { result = info; });
  assert.equal(result.cpuAbi, 'arm64-v8a,armeabi-v7a');
  assert.equal(result.totalMemory, '8.00 GiB');
});

test('omits unsupported device readings and preserves other fields', async () => {
  const { DevToolsInfoSession } = loadInfo(async () => ({ name: 'test.app', versionCode: 2 }), {
    '@kit.BasicServicesKit': { deviceInfo: { abiList: '  ', sdkApiVersion: 20 } },
    '@kit.PerformanceAnalysisKit': { hidebug: { getSystemMemInfo() { throw new Error('not supported'); } } }
  });
  let result;
  await new DevToolsInfoSession().loadBasic(info => { result = info; });
  assert.equal(result.cpuAbi, undefined);
  assert.equal(result.totalMemory, undefined);
  assert.equal(result.packageName, 'test.app');
});

test('the device shortcut reads hardware independently of the host package and permissions', () => {
  let bundleReads = 0;
  const { readDevToolsDeviceInfo } = loadInfo(() => { bundleReads++; }, {
    '@kit.BasicServicesKit': { deviceInfo: { brand: ' Example ', manufacture: 'Factory', productModel: 'P2',
      deviceType: 'tablet', abiList: 'arm64-v8a', sdkApiVersion: 20 } },
    '@kit.PerformanceAnalysisKit': { hidebug: { getSystemMemInfo: () => ({ totalMem: 4194304n }) } }
  });
  const device = readDevToolsDeviceInfo();
  assert.equal(device.brand, 'Example');
  assert.equal(device.manufacturer, 'Factory');
  assert.equal(device.deviceType, 'tablet');
  assert.equal(device.deviceModel, 'P2');
  assert.equal(device.totalMemory, '4.00 GiB');
  assert.equal(bundleReads, 0);
});

test('storage reports free and total bytes including a full disk, and tolerates a missing service', async () => {
  const { readDevToolsStorage } = loadInfo(undefined, {
    '@kit.CoreFileKit': { storageStatistics: { getFreeSize: async () => 0, getTotalSize: async () => 2 ** 32 } }
  });
  assert.equal(await readDevToolsStorage(), '0.00 GiB/4.00 GiB');
  assert.equal(await loadInfo(undefined).readDevToolsStorage(), undefined);
});

test('tracks the host display through rotation, migration, temporary failure and unmount', () => {
  let displayId = 7;
  const data = new Map([
    [7, { width: 1080, height: 2400, orientation: 0, xDPI: 400, yDPI: 400, densityPixels: 2.5, densityDPI: 400, refreshRate: 120 }],
    [9, { width: 1920, height: 1080, xDPI: 0, yDPI: 0, densityPixels: 1, densityDPI: 160, refreshRate: 60 }]
  ]);
  let displayChanged, windowMoved;
  const removed = [];
  const host = {
    getWindowProperties: () => ({ displayId, windowRect: { width: 400, height: 300 } }),
    on(event, callback) { assert.equal(event, 'displayIdChange'); windowMoved = callback; },
    off(event, callback) { assert.equal(callback, windowMoved); removed.push(event); }
  };
  const display = {
    Orientation: { PORTRAIT: 0, LANDSCAPE: 1, PORTRAIT_INVERTED: 2, LANDSCAPE_INVERTED: 3 },
    getDisplayByIdSync(id) { if (!data.has(id)) { throw new Error('detached'); } return data.get(id); },
    on(event, callback) { assert.equal(event, 'change'); displayChanged = callback; },
    off(event, callback) { assert.equal(callback, displayChanged); removed.push(event); }
  };
  const { DevToolsDisplaySession } = loadInfo(undefined, { '@kit.ArkUI': { display } });
  const published = [];
  const session = new DevToolsDisplaySession(host, metrics => published.push(metrics));
  session.refresh();
  assert.deepEqual(published.at(-1), {
    resolution: '1080x2400', logicalSize: '432 × 960 vp', orientation: '竖屏', screenInches: '6.6 英寸',
    density: '2.5', densityDpi: '400 dpi', refreshRate: '120 Hz'
  });
  const calls = published.length;
  displayChanged(9);
  assert.equal(published.length, calls);
  data.set(7, { ...data.get(7), width: 2400, height: 1080, orientation: 3, refreshRate: 90 });
  displayChanged(7);
  assert.equal(published.at(-1).resolution, '2400x1080');
  assert.equal(published.at(-1).refreshRate, '90 Hz');
  assert.equal(published.at(-1).orientation, '反向横屏');
  assert.equal(published.at(-1).logicalSize, '960 × 432 vp');
  displayId = 9;
  windowMoved(9);
  assert.equal(published.at(-1).resolution, '1920x1080');
  assert.equal(published.at(-1).screenInches, undefined);
  assert.equal(published.at(-1).orientation, undefined);
  displayId = 100;
  windowMoved(100);
  assert.equal(published.at(-1), undefined);
  session.dispose();
  const afterDispose = published.length;
  windowMoved(7);
  displayChanged(7);
  session.refresh();
  assert.equal(published.length, afterDispose);
  assert.deepEqual(removed.sort(), ['change', 'displayIdChange']);
});

test('shows the API level packed by DevEco and plain API levels', () => {
  const { devToolsTargetApi } = loadInfo(undefined);
  assert.equal(devToolsTargetApi(260000026), '26');
  assert.equal(devToolsTargetApi(60000020), '20');
  assert.equal(devToolsTargetApi(12), '12');
  assert.equal(devToolsTargetApi(0), undefined);
});

test('uses the default screen only when a successful window query omits its display id', () => {
  let windowProperties = {};
  let primaryReads = 0;
  const host = {
    getWindowProperties() {
      if (!windowProperties) { throw new Error('window closed'); }
      return windowProperties;
    },
    on() {}, off() {}
  };
  const display = {
    getDefaultDisplaySync() { primaryReads++; return { id: 0, width: 720, height: 1280 }; },
    getDisplayByIdSync() { throw new Error('display removed'); },
    on() {}, off() {}
  };
  const { DevToolsDisplaySession } = loadInfo(undefined, { '@kit.ArkUI': { display } });
  const published = [];
  const session = new DevToolsDisplaySession(host, metrics => published.push(metrics));
  session.refresh();
  assert.equal(published.at(-1)?.resolution, '720x1280');
  assert.equal(published.at(-1)?.logicalSize, undefined);
  windowProperties = { displayId: 9 };
  session.refresh();
  assert.equal(published.at(-1), undefined);
  windowProperties = undefined;
  session.refresh();
  assert.equal(published.at(-1), undefined);
  assert.equal(primaryReads, 1);
  session.dispose();
});
