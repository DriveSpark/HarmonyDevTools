const { test } = require('node:test');
const assert = require('node:assert/strict');
require('./register.cjs');
const { DevToolsRulerGeometry } = require('../devtools/src/main/ets/DevToolsRulerGeometry.ets');

test('the marker starts one radius beyond the center and only the top distance includes the status bar', () => {
  const g = new DevToolsRulerGeometry({ left: 8, top: 32, right: 368, bottom: 744 }, 376);
  const marker = g.markerPosition();
  assert.deepEqual(marker, { x: 210, y: 386 });
  assert.deepEqual(g.distances(marker, 2.5, 0), { left: 525, right: 375, top: 965, bottom: 815 });
  assert.deepEqual(g.distances(marker, 2.5, 24), { left: 525, right: 375, top: 1025, bottom: 815 });
});

test('the center reaches all four edges and complementary distances sum to the real pixel dimensions', () => {
  const g = new DevToolsRulerGeometry({ left: 0, top: 24, right: 319.6, bottom: 510.9 }, 320);
  const widthPx = Math.round(319.6 * 2.625);
  const heightPx = Math.round(486.9 * 2.625);
  for (const [x, y, left, bottom] of [[-50, 900, 0, 0], [900, -50, widthPx, heightPx],
    [17.3, 168.5, 45, heightPx - Math.round(168.5 * 2.625)]]) {
    const marker = g.markerPosition(g.markerFraction(x, y));
    const d = g.distances(marker, 2.625, 0);
    assert.equal(d.left, left);
    assert.equal(d.bottom, bottom);
    assert.equal(d.left + d.right, widthPx);
    assert.equal(d.top + d.bottom, heightPx);
  }
});

test('a dragged marker and card stay in the usable area after rotation and keyboard changes', () => {
  const portrait = new DevToolsRulerGeometry({ left: 0, top: 24, right: 360, bottom: 704 }, 360);
  const landscape = new DevToolsRulerGeometry({ left: 24, top: 0, right: 704, bottom: 360 }, 360);
  assert.deepEqual(portrait.cardPosition(), { x: 15, y: 530 });
  assert.equal(portrait.cardWidth, 330);
  assert.equal(portrait.cardHeight, 100);
  const marker = portrait.markerFraction(90, 340);
  assert.deepEqual(landscape.markerPosition(marker), { x: 170, y: 180 });
  const atEnd = landscape.cardFraction(900, 450);
  assert.deepEqual(landscape.cardPosition(atEnd), { x: 335, y: 260 });
  assert.deepEqual(portrait.cardPosition(atEnd), { x: 15, y: 580 });
  const raised = portrait.cardFraction(15, 290, atEnd);
  assert.deepEqual(landscape.cardPosition(raised), { x: 335, y: 130 });
  const keyboard = new DevToolsRulerGeometry({ left: 0, top: 24, right: 360, bottom: 97 }, 360);
  assert.equal(keyboard.cardWidth, 330);
  assert.equal(keyboard.cardHeight, 73);
  assert.deepEqual(keyboard.cardPosition(raised), { x: 15, y: 0 });
});
