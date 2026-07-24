'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const { AgentTabRegistry } = require('../agentTabRegistry');

function tab(label, active = false) {
  return { label, isActive: active, input: { viewType: 'claudeVSCodePanel' } };
}

test('agent tab identity survives native pin reorder, wrapper churn, and title change', () => {
  let token = 0;
  const registry = new AgentTabRegistry('window-a', () => `${++token}`);
  const first = tab('First');
  const second = tab('Second');
  const third = tab('Third', true);
  registry.refresh([{ viewColumn: 1, isActive: true, tabs: [first, second, third] }]);
  const firstID = registry.idFor(first);
  const secondID = registry.idFor(second);
  const thirdID = registry.idFor(third);

  // Model VS Code replacing wrappers and moving the newly-native-pinned third
  // conversation to the start of its pinned section.
  const movedThird = tab('Third', true);
  const replacedFirst = tab('First');
  const replacedSecond = tab('Second');
  registry.refresh(
    [{ viewColumn: 1, isActive: true, tabs: [movedThird, replacedFirst, replacedSecond] }],
    thirdID
  );
  assert.equal(registry.idFor(movedThird), thirdID);
  assert.equal(registry.idFor(replacedFirst), firstID);
  assert.equal(registry.idFor(replacedSecond), secondID);

  // Claude titles a new conversation after its first prompt. Same position,
  // different title and wrappers must retain the exact pin.
  const titledThird = tab('Fix the backend', true);
  registry.refresh([{ viewColumn: 1, isActive: true, tabs: [titledThird, tab('First'), tab('Second')] }]);
  assert.equal(registry.idFor(titledThird), thirdID);
});

test('preferred active identity disambiguates identical default-title tabs during pin reorder', () => {
  let token = 0;
  const registry = new AgentTabRegistry('window-b', () => `${++token}`);
  const one = tab('Claude Code');
  const two = tab('Claude Code');
  const three = tab('Claude Code', true);
  registry.refresh([{ viewColumn: 1, isActive: true, tabs: [one, two, three] }]);
  const thirdID = registry.idFor(three);

  const movedThree = tab('Claude Code', true);
  registry.refresh(
    [{ viewColumn: 1, isActive: true, tabs: [movedThree, tab('Claude Code'), tab('Claude Code')] }],
    thirdID
  );
  assert.equal(registry.idFor(movedThree), thirdID,
    'the active third conversation keeps its id instead of donating it to the first sibling');
});
