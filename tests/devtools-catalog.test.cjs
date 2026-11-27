const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(path.join(process.env.DEVECO_HOME || 'C:/Program Files/Huawei/DevEco Studio',
  'tools/hvigor/hvigor/node_modules/typescript'));

const source = fs.readFileSync(path.join(__dirname, '../devtools/src/main/ets/DevToolsCatalogSettings.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: {
  target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true
} }).outputText;

function catalog(initialValue = '') {
  const store = {
    cache: initialValue, disk: initialValue, failFlush: false,
    getSync() { return this.cache; },
    putSync(key, next) { this.cache = next; },
    flushSync() {
      if (this.failFlush) { throw new Error('write failed'); }
      this.disk = this.cache;
    }
  };
  const exports = {};
  const kit = { preferences: { getPreferencesSync: () => store } };
  new Function('require', 'exports', 'Trace', 'ObservedV2', compiled)(() => kit, exports, () => {}, klass => klass);
  const open = () => {
    const settings = new exports.DevToolsCatalogState();
    settings.load({});
    return settings;
  };
  return { store, open };
}

function ids(settings, group, manage = false) {
  return settings.tools(group, manage).map(tool => tool.id);
}

const commonTools = ['appinfo', 'deviceinfo', 'screeninfo', 'developer', 'logs'];
const visualTools = ['ruler', 'colorpicker', 'inspector', 'borders'];

test('edit previews all built-ins and back can discard without changing the catalog or storage', () => {
  const { store, open } = catalog();
  const settings = open();
  settings.beginEditing();
  settings.toggle('appinfo');
  assert.deepEqual(settings.tools('common', true), commonTools.map(id => ({ id, group: 'common', checked: id !== 'appinfo' })));
  assert.deepEqual(ids(settings, 'common'), commonTools);
  assert.equal(settings.requestManagerBack(), true);
  assert.equal(settings.requestManagerBack(), true);
  settings.dismissNotice();
  assert.equal(settings.dialog, 'save');
  assert.equal(settings.resolveConfirmation(false), true);
  assert.equal(settings.editing, false);
  assert.deepEqual(ids(settings, 'common'), commonTools);
  assert.equal(store.disk, '');
});

test('saving preserves same-group order, cross-group placement, and hidden tools on reopening', () => {
  const { store, open } = catalog();
  const settings = open();
  settings.beginEditing();
  assert.equal(settings.move('crash', 'ruler'), 'moved');
  assert.equal(settings.move('cpu', 'memory'), 'moved');
  assert.deepEqual(ids(settings, 'performance', true), ['memory', 'cpu']);
  assert.equal(settings.move('cpu', 'appinfo'), 'moved');
  assert.deepEqual(ids(settings, 'common', true), ['cpu', ...commonTools]);
  assert.equal(settings.move('memory', 'appinfo'), 'lastInGroup');
  settings.toggle('memory');
  settings.finishEditing();
  assert.equal(settings.dialog, 'saved');
  assert.equal(settings.requestManagerBack(), true);
  assert.equal(settings.requestManagerBack(), false);
  const reopened = catalog(store.disk).open();
  assert.deepEqual(ids(reopened, 'common'), ['cpu', ...commonTools]);
  assert.deepEqual(ids(reopened, 'performance'), []);
  reopened.beginEditing();
  assert.deepEqual(ids(reopened, 'performance', true), ['memory']);
});

test('back can save directly and confirmed restore replaces sorting and visibility with the defaults', () => {
  const { store, open } = catalog();
  const settings = open();
  settings.beginEditing();
  settings.toggle('appinfo');
  settings.move('memory', 'cpu');
  settings.requestManagerBack();
  assert.equal(settings.resolveConfirmation(true), true);
  assert.deepEqual(ids(settings, 'common'), commonTools.slice(1));
  assert.deepEqual(ids(settings, 'performance'), ['memory', 'cpu', 'crash']);
  settings.beginEditing();
  settings.requestReset();
  assert.equal(settings.requestManagerBack(), true);
  settings.dismissNotice();
  assert.equal(settings.dialog, 'reset');
  assert.equal(settings.resolveConfirmation(false), false);
  assert.equal(settings.editing, true);
  assert.deepEqual(ids(settings, 'performance', true), ['memory', 'cpu', 'crash']);
  settings.requestReset();
  assert.equal(settings.resolveConfirmation(true), false);
  assert.equal(settings.dialog, 'restored');
  assert.equal(settings.editing, false);
  settings.dismissNotice();
  assert.equal(settings.dialog, 'none');
  const reopened = catalog(store.disk).open();
  assert.deepEqual(ids(reopened, 'common'), commonTools);
  assert.deepEqual(ids(reopened, 'performance'), ['cpu', 'memory', 'crash']);
});

test('a failed save retains the draft and restores the shared preferences cache until retry', () => {
  const { store, open } = catalog();
  const settings = open();
  settings.beginEditing();
  settings.toggle('cpu');
  settings.requestManagerBack();
  store.failFlush = true;
  assert.equal(settings.resolveConfirmation(true), false);
  assert.equal(settings.dialog, 'failed');
  assert.equal(settings.editing, true);
  assert.deepEqual(ids(open(), 'performance'), ['cpu', 'memory', 'crash']);
  assert.equal(store.disk, '');
  settings.dismissNotice();
  store.failFlush = false;
  settings.finishEditing();
  assert.equal(settings.dialog, 'saved');
  assert.deepEqual(ids(catalog(store.disk).open(), 'performance'), ['memory', 'crash']);
});

test('upgrading adds the ruler and preserves a saved layout from the three-tool version', () => {
  const previous = JSON.stringify([
    { id: 'memory', group: 'performance', checked: false },
    { id: 'cpu', group: 'common', checked: true },
    { id: 'appinfo', group: 'common', checked: true }
  ]);
  const { store, open } = catalog(previous);
  const settings = open();
  assert.deepEqual(ids(settings, 'visual'), visualTools);
  assert.deepEqual(ids(settings, 'common'), ['cpu', ...commonTools]);
  assert.deepEqual(ids(settings, 'performance'), ['crash']);
  settings.beginEditing();
  for (const id of visualTools.slice(1)) { assert.equal(settings.move(id, 'crash'), 'moved'); }
  assert.equal(settings.move('ruler', 'appinfo'), 'lastInGroup');
  assert.equal(settings.move('cpu', 'ruler'), 'moved');
  settings.toggle('ruler');
  settings.finishEditing();
  const reopened = catalog(store.disk).open();
  assert.deepEqual(ids(reopened, 'visual'), ['cpu']);
  reopened.beginEditing();
  assert.deepEqual(ids(reopened, 'visual', true), ['ruler', 'cpu']);
});

test('version 1.2 layouts gain both shortcuts and persist their independent visibility and order', () => {
  const previous = JSON.stringify([
    { id: 'appinfo', group: 'common', checked: false },
    { id: 'memory', group: 'performance', checked: false },
    { id: 'cpu', group: 'performance', checked: true },
    { id: 'ruler', group: 'visual', checked: true }
  ]);
  const { store, open } = catalog(previous);
  const settings = open();
  assert.deepEqual(ids(settings, 'common'), commonTools.slice(1));
  assert.deepEqual(ids(settings, 'performance'), ['cpu', 'crash']);
  settings.beginEditing();
  assert.equal(settings.move('screeninfo', 'deviceinfo'), 'moved');
  settings.toggle('deviceinfo');
  settings.finishEditing();
  const reopened = catalog(store.disk).open();
  assert.deepEqual(ids(reopened, 'common'), ['screeninfo', 'developer', 'logs']);
  reopened.beginEditing();
  assert.deepEqual(ids(reopened, 'common', true), ['appinfo', 'screeninfo', 'deviceinfo', 'developer', 'logs']);
});

test('version 1.3 customized layout gains all six tools exactly once without reviving hidden shortcuts', () => {
  const old = [
    { id: 'screeninfo', group: 'common', checked: false }, { id: 'deviceinfo', group: 'visual', checked: true },
    { id: 'appinfo', group: 'common', checked: true }, { id: 'cpu', group: 'performance', checked: false },
    { id: 'memory', group: 'performance', checked: true }, { id: 'ruler', group: 'visual', checked: false }
  ];
  const settings = catalog(JSON.stringify(old)).open();
  assert.deepEqual(ids(settings, 'common'), ['appinfo', 'developer', 'logs']);
  assert.deepEqual(ids(settings, 'performance'), ['memory', 'crash']);
  assert.deepEqual(ids(settings, 'visual'), ['deviceinfo', 'colorpicker', 'inspector', 'borders']);
});
