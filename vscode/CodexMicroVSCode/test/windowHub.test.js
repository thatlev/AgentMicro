'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { WindowHub } = require('../windowHub');

test('multi-window hub retains targets and routes concrete operations to their project', () => {
  const hub = new WindowHub('project-a');
  hub.updateWindow('project-a', {
    focused: true,
    targets: [
      { id: 'a:first', kind: 'agent-editor', label: 'First', active: false },
      { id: 'a:second', kind: 'agent-editor', label: 'Second', active: false },
      { id: 'a:third', kind: 'agent-editor', label: 'Third', active: true },
    ],
  });
  hub.updateWindow('project-b', {
    focused: false,
    targets: [
      { id: 'b:claude', kind: 'agent-editor', label: 'Other project', active: true },
    ],
  });

  assert.deepEqual(hub.targets().map((target) => target.id), [
    'a:first', 'a:second', 'a:third', 'b:claude',
  ], 'targets from both projects remain registered together');
  assert.deepEqual(hub.targets().filter((target) => target.active).map((target) => target.id), [
    'a:third',
  ], 'only the focused project contributes the live active tab');
  assert.equal(hub.routeFor({ op: 'focus', id: 'a:third' }), 'project-a');
  assert.equal(hub.routeFor({ op: 'voice', id: 'b:claude', active: true }), 'project-b');
  assert.equal(hub.routeFor({ op: 'pins', pins: ['a:third', 'b:claude'] }), '*');

  hub.updateWindow('project-b', { focused: true });
  assert.deepEqual(hub.targets().filter((target) => target.active).map((target) => target.id), [
    'b:claude',
  ]);
  assert.equal(hub.routeFor({ op: 'new', kind: 'command', value: 'claude.new' }), 'project-b',
    'untargeted NEW follows the most recently focused project');
  assert.equal(hub.routeFor({ op: 'command', cmd: 'workbench.action.test' }), 'project-b');

  hub.removeWindow('project-b');
  assert.deepEqual(hub.targets().map((target) => target.id), ['a:first', 'a:second', 'a:third']);
  assert.equal(hub.routeFor({ op: 'focus', id: 'a:third' }), 'project-a');
});
