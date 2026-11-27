const { test } = require('node:test');
const assert = require('node:assert/strict');
require('./register.cjs');
const { DevToolsController } = require('../devtools/src/main/ets/DevToolsController.ets');

test('a replacement keeps its slot and survives removal of the previous registration', () => {
  const tools = new DevToolsController();
  const old = tools.register({ id: 'a', title: 'Old', group: 'Tools', onSelect() {} });
  tools.register({ id: 'b', title: 'Second', group: 'Tools', onSelect() {} });
  const latest = tools.register({ id: 'a', title: 'New', group: 'Tools', onSelect() {} });
  old();
  assert.deepEqual(tools.getTools().map(item => item.title), ['New', 'Second']);
  latest();
  latest();
  assert.deepEqual(tools.getTools().map(item => item.id), ['b']);
});

test('selecting a registered action closes the panel before invoking the host', () => {
  const tools = new DevToolsController();
  const observations = [];
  tools.register({ id: 'inspect', title: 'Inspect', group: 'Tools', onSelect() {
    observations.push(['host', tools.isOpen]);
  } });
  const stop = tools.subscribe(() => observations.push(['panel', tools.isOpen]));
  tools.open();
  tools.select('inspect');
  assert.deepEqual(observations, [['panel', true], ['panel', false]]);
  tools.panelDidDisappear();
  tools.panelDidDisappear();
  assert.deepEqual(observations, [['panel', true], ['panel', false], ['host', false]]);
  stop();
  tools.open();
  assert.equal(tools.close(), true);
  assert.equal(tools.close(), false);
  assert.equal(observations.length, 3);
});

test('a detached, replaced or disposed host action cannot run after the dismiss animation', () => {
  for (const invalidate of ['close', 'open', 'unregister', 'replace', 'dispose']) {
    const tools = new DevToolsController();
    let called = 0;
    const action = { id: 'test', title: 'Test', group: 'Tools', onSelect() { called++; } };
    const unregister = tools.register(action);
    tools.open();
    tools.select('test');
    if (invalidate === 'unregister') { unregister(); }
    else if (invalidate === 'replace') { tools.register(action); }
    else { tools[invalidate](); }
    tools.panelDidDisappear();
    assert.equal(called, 0, invalidate);
  }
});

test('separate hosts have independent tools and disposal drops callbacks', () => {
  const first = new DevToolsController();
  const other = new DevToolsController();
  let called = 0;
  first.register({ id: 'local', title: 'Local', group: 'Tools', onSelect() { called++; } });
  first.open();
  first.dispose();
  first.select('local');
  assert.equal(first.isOpen, false);
  assert.deepEqual(first.getTools(), []);
  assert.deepEqual(other.getTools(), []);
  assert.equal(called, 0);
});

test('hardware back delegates to the current panel and clears its handler on detach', () => {
  const tools = new DevToolsController();
  let page = 'info';
  const detachOld = tools.bindPanelBack(() => assert.fail('detached view received back'));
  const detach = tools.bindPanelBack(() => { page = 'tools'; });
  detachOld();
  assert.equal(tools.handleBack(), false);
  tools.open();
  assert.equal(tools.handleBack(), true);
  assert.equal(page, 'tools');
  assert.equal(tools.isOpen, true);
  detach();
  assert.equal(tools.handleBack(), true);
  assert.equal(tools.isOpen, false);
});

test('registration retains the host tool icon', () => {
  const tools = new DevToolsController();
  const icon = { id: 42 };
  tools.register({ id: 'example', group: 'Host', title: 'Go', icon, onSelect() {} });
  assert.equal(tools.getTools()[0].icon, icon);
});

test('back collapses a live viewer once, prioritizes an open catalog, then returns control to the host', () => {
  const tools = new DevToolsController();
  let expanded = true;
  const old = tools.bindOverlayBack(() => assert.fail('detached viewer received back'));
  tools.bindOverlayBack(() => {
    const handled = expanded;
    expanded = false;
    return handled;
  });
  old();
  tools.open();
  assert.equal(tools.handleBack(), true);
  assert.equal(expanded, true);
  assert.equal(tools.handleBack(), true);
  assert.equal(tools.handleBack(), false);
  tools.dispose();
  expanded = true;
  assert.equal(tools.handleBack(), false);
});

test('listeners attached during a notification receive subsequent changes', () => {
  const tools = new DevToolsController();
  const events = [];
  let first = true;
  tools.subscribe(() => {
    if (first) {
      first = false;
      tools.subscribe(() => events.push(tools.isOpen));
    }
  });
  tools.open();
  assert.deepEqual(events, []);
  tools.close();
  assert.deepEqual(events, [false]);
});
