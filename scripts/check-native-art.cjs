const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const generated = fs.readFileSync(path.join(root, 'JotBloom/Resources/Companions/native-renderer.js'), 'utf8');
function engine(resident) {
  const context = vm.createContext({});
  vm.runInContext(fs.readFileSync(path.join(root, 'JotBloom/Resources/Companions/companion-engine.js'), 'utf8'), context);
  vm.runInContext(generated, context);
  context.NativeCompanion.init({ resident, backdrop: true, frequency: 50 });
  return context.NativeCompanion;
}
const operations = new Set(['save', 'restore', 'transform', 'translate', 'scale', 'rotate', 'begin', 'rect', 'fillRect', 'fill', 'clip', 'color', 'alpha']);
test('approved motion runs without a DOM and only emits supported, balanced finite drawing commands', () => {
  for (const resident of [true, false]) for (const character of ['chuichui', 'yuntuan', 'dujiao', 'momo', 'lili', 'mumu']) {
    const api = engine(resident);
    for (const mood of ['idle', 'curious', 'sleep', 'energetic', 'tired', 'receive', 'satisfied', 'notify']) {
      api.action('preview', mood);
      for (let t = 0; t < 120; t++) {
        const frame = api.frame(1 / 30, character, 0.2, -0.1);
        let depth = 0;
        for (const [op, ...args] of frame.commands) {
          assert.ok(operations.has(op), op);
          for (const arg of args) if (typeof arg === 'number') assert.ok(Number.isFinite(arg), `${character}/${mood}/${op}`);
          if (op === 'save') depth++;
          if (op === 'restore') depth--;
          assert.ok(depth >= 0);
        }
        assert.equal(depth, 0);
      }
    }
  }
});
test('switching character during a panel retreat keeps lifecycle position and event state', () => {
  const api = engine(true);
  api.action('event', 'receive'); api.frame(.2, 'chuichui'); api.action('panel', true);
  const before = api.frame(.1, 'chuichui').state;
  const after = api.frame(0, 'yuntuan').state;
  assert.equal(after.x, before.x); assert.equal(after.phase, before.phase);
  assert.equal(after.queued.receive, true);
  api.frame(.25, 'dujiao');
  assert.equal(api.state().phase, 'hidden');
});
