const { test } = require('node:test');
const assert = require('node:assert/strict');
require('./register.cjs');
const {
  readDevToolsNodeTree, findDevToolsNodeHits, localDevToolsNodeRect, cycleDevToolsNodeHit,
  sameDevToolsNodeTree, DEVTOOLS_INSPECTOR_NODE_LIMIT, DEVTOOLS_INSPECTOR_JSON_LIMIT
} = require('../devtools/src/main/ets/DevToolsNodeTree.ets');
const { describeDevToolsNode } = require('../devtools/src/main/ets/DevToolsNodeDetails.ets');

const viewport = { windowX: 10, windowY: 20, width: 100, height: 150, density: 2 };
const frame = () => ({ visible: true, clipsChildren: false });
function node(type, uid, rect, id = '', children = []) {
  return { $type: type, $ID: uid, $rect: rect, $attrs: { id }, $children: children };
}
function tree(children, probe = frame, overlayId = 77) {
  return readDevToolsNodeTree(JSON.stringify({ $type: 'root', $children: children }), viewport, overlayId, probe);
}
const full = '[20.00, 40.00],[220.00,340.00]';

test('window pixel rectangles map to the offset overlay and front siblings, descendants and parents cycle in order', () => {
  const snapshot = tree([node('Column', 1, full, 'page', [
    node('Text', 2, '[30,60],[122,124]', 'back'),
    node('Stack', 3, '[40,68],[120,128]', '', [node('Text', 4, '[48,80],[100,108]')])
  ])]);
  assert.equal(snapshot.status, 'ready');
  const hits = findDevToolsNodeHits(snapshot, viewport, 17, 25);
  assert.deepEqual(hits.map(hit => hit.uniqueId), [4, 3, 2, 1]);
  assert.equal(hits[0].inspectorId, '');
  assert.equal(hits[2].inspectorId, 'back');
  assert.deepEqual(localDevToolsNodeRect(hits[0].rect, viewport), { left: 14, top: 20, right: 40, bottom: 34 });
  assert.deepEqual(findDevToolsNodeHits(snapshot, viewport, 40, 34).map(hit => hit.uniqueId), [3, 2, 1]);
  assert.equal(cycleDevToolsNodeHit(0, hits.length, -1), 3);
  assert.equal(cycleDevToolsNodeHit(3, hits.length, 1), 0);
  assert.equal(cycleDevToolsNodeHit(0, 0, -1), -1);
});

test('tool root, cover, hidden subtree and offscreen nodes stay out; Web and Canvas expose only their host frames', () => {
  const probeIds = [];
  const snapshot = tree([
    node('Text', 10, full, 'devtools_related_host_id'),
    node('Stack', 11, full, 'devtools_overlay', [node('Button', 12, full)]),
    node('Stack', 77, full, '', [node('Button', 13, full)]),
    node('Stack', 14, full, 'devtools_cover', [node('Text', 15, full)]),
    node('Row', 16, full, '', [node('Text', 17, full)]),
    node('Web', 18, full, '', [node('Text', 19, full)]),
    node('Canvas', 20, full, '', [node('Image', 21, full)]),
    node('XComponent', 24, full, '', [node('Text', 25, full)]),
    node('Text', 22, '[-50,-50],[10,10]'),
    node('Column', 23, full)
  ], id => {
    probeIds.push(id);
    if (id === 23) { return undefined; }
    return { visible: id !== 16, clipsChildren: false };
  });
  assert.deepEqual(snapshot.nodes.map(item => item.uniqueId), [24, 20, 18, 10]);
  for (const id of [11, 12, 13, 14, 15, 17, 19, 21, 25, 77]) { assert.ok(!probeIds.includes(id)); }
});

test('only clipped parents constrain descendants, including when scrolling moves a child across the clip edge', () => {
  const snapshot = tree([
    node('Scroll', 11, '[38,55],[120,100]', '', [node('Text', 12, '[38,88],[100,130]')]),
    node('Stack', 20, '[400,400],[440,440]', '', [node('Text', 21, '[40,116],[100,140]')])
  ], id => ({ visible: true, clipsChildren: id === 11 }));
  assert.deepEqual(findDevToolsNodeHits(snapshot, viewport, 14, 26).map(hit => hit.uniqueId), [12, 11]);
  assert.deepEqual(findDevToolsNodeHits(snapshot, viewport, 14, 38).map(hit => hit.uniqueId), [21]);
  assert.deepEqual(snapshot.nodes.find(item => item.uniqueId === 12).visibleRect, { left: 38, top: 88, right: 100, bottom: 100 });
});

test('malformed and oversized trees return explicit states; bounded traversal prioritizes the front of a large stack', () => {
  const read = data => readDevToolsNodeTree(data, viewport, -1, frame);
  for (const raw of ['{', 'null', '[]', '{}']) { assert.equal(read(raw).status, 'unavailable'); }
  assert.equal(read(' '.repeat(DEVTOOLS_INSPECTOR_JSON_LIMIT + 1)).status, 'oversized');
  const bad = tree([node('Text', 1, '[,40],[30,70]'), node('Text', 2, '[10,10],[10,20]'),
    node('Text', 3, '[20,NaN],[30,70]'), node('Text', 4, '24,44,80,60')]);
  assert.deepEqual(bad.nodes.map(item => item.uniqueId), [4]);
  assert.deepEqual(bad.nodes[0].rect, { left: 24, top: 44, right: 104, bottom: 104 });
  const many = Array.from({ length: DEVTOOLS_INSPECTOR_NODE_LIMIT + 22 }, (_, i) => node('Text', i + 100, full));
  const bounded = tree(many);
  assert.equal(bounded.status, 'partial');
  assert.ok(bounded.nodes.length <= DEVTOOLS_INSPECTOR_NODE_LIMIT);
  assert.equal(bounded.nodes[0].uniqueId, many.at(-1).$ID);
  assert.equal(sameDevToolsNodeTree(bad, bad), true);
  assert.equal(sameDevToolsNodeTree(bad, bounded), false);
  assert.equal(sameDevToolsNodeTree(tree([node('Text', 4, full)]), tree([node('Text', 4, full, 'new')])), false);
});

test('details use the live inspector id and measured px size, independent of the transformed highlight rectangle', () => {
  const selected = tree([node('Text', 7, '[36,70],[120,110]', 'stale-id')]).nodes[0];
  const fake = {
    isDisposed: () => false, isAttached: () => true, getId: () => '',
    getMeasuredSize: () => ({ width: 42, height: 20 }),
    getInspectorInfo: () => ({ $attrs: {
      fontSize: '16.00fp', fontColor: '#FF000000', backgroundColor: '#00000000', content: 'host private content',
      padding: '{"top":"0.00vp","right":"4.00vp","bottom":"0.00vp","left":"4.00vp"}', margin: '0.00vp'
    } })
  };
  const details = describeDevToolsNode(selected, fake);
  assert.match(details, /控件 ID：未设置/);
  assert.match(details, /节点编号：7/);
  assert.match(details, /42 × 20 px/);
  assert.match(details, /窗口位置：36, 70 px/);
  assert.match(details, /字号：16.00fp/);
  assert.match(details, /内边距（上右下左）：0.00vp 4.00vp 0.00vp 4.00vp/);
  assert.doesNotMatch(details, /stale-id|host private content|背景色|外边距/);
  let infoReads = 0;
  const protectedFrame = { ...fake, getInspectorInfo: () => { infoReads++; return {}; } };
  for (const componentType of ['TextInput', 'Web', 'XComponent']) {
    describeDevToolsNode({ ...selected, componentType }, protectedFrame);
  }
  assert.equal(infoReads, 0);
  assert.doesNotThrow(() => describeDevToolsNode(selected, { isDisposed: () => { throw Error('detached'); } }));
  assert.match(describeDevToolsNode(selected, null), /84 × 40 px/);
});
