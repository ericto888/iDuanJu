'use strict';

const assert = require('assert');
const {
  BUG_REPORT_RULES_EFFECTIVE_AT,
  decideBugIssueAction,
} = require('./validate-bug-issue.js');

const AFTER = '2026-11-25T15:00:00Z';
const HISTORICAL = '2026-11-25T14:26:56Z';

function bugIssue(overrides = {}) {
  return {
    title: '[Bug] 无法播放',
    body: '',
    labels: [{ name: 'bug' }],
    created_at: AFTER,
    ...overrides,
  };
}

function formBody({ os = 'Android 14', app = '1.6b36', desc = '打开某部剧后无法播放' } = {}) {
  return [
    '### 系统版本',
    '',
    os,
    '',
    '### 软件版本',
    '',
    app,
    '',
    '### Bug 描述',
    '',
    desc,
    '',
    '### 复现步骤',
    '',
    '_No response_',
  ].join('\n');
}

const cases = [
  {
    name: 'valid three fields from issue form',
    issue: bugIssue({ body: formBody() }),
    expected: { close: false, reason: 'complete' },
  },
  {
    name: 'valid three fields from labeled lines via API',
    issue: bugIssue({
      title: '播放失败',
      body: '系统版本：iOS 17.5\n软件版本: 1.6b36\nBug描述：返回桌面后仍在播放',
    }),
    expected: { close: false, reason: 'complete' },
  },
  {
    name: 'missing 系统版本',
    issue: bugIssue({ body: formBody({ os: '' }) }),
    close: true,
    missing: '系统版本',
  },
  {
    name: 'missing 软件版本',
    issue: bugIssue({ body: formBody({ app: '   ' }) }),
    close: true,
    missing: '软件版本',
  },
  {
    name: 'missing Bug描述',
    issue: bugIssue({ body: formBody({ desc: '' }) }),
    close: true,
    missing: 'Bug描述',
  },
  {
    name: 'blank _No response_ for 系统版本',
    issue: bugIssue({ body: formBody({ os: '_No response_' }) }),
    close: true,
    missing: '系统版本',
  },
  {
    name: 'blank _No response_ for 软件版本 is case-insensitive',
    issue: bugIssue({ body: formBody({ app: '_no response_' }) }),
    close: true,
    missing: '软件版本',
  },
  {
    name: 'API bypass with bug label and empty body',
    issue: bugIssue({ title: '无法播放', body: '' }),
    close: true,
    missing: ['系统版本', '软件版本', 'Bug描述'],
  },
  {
    name: 'bug title without label still validated',
    issue: {
      title: '[Bug] 闪退',
      body: formBody({ desc: '_No response_' }),
      labels: [],
      created_at: AFTER,
    },
    close: true,
    missing: 'Bug描述',
  },
  {
    name: 'non-bug feature request is not closed',
    issue: {
      title: '[功能建议] 增加投屏',
      body: '希望增加投屏功能',
      labels: [{ name: 'enhancement' }],
      created_at: AFTER,
    },
    expected: { close: false, reason: 'not_bug' },
  },
  {
    name: 'blank non-bug issue is not treated as a bug report',
    issue: {
      title: '希望增加书架管理',
      body: '希望可以删除多余的书',
      labels: [],
      created_at: AFTER,
    },
    expected: { close: false, reason: 'not_bug' },
  },
  {
    name: 'historical incomplete bug report is not closed',
    issue: bugIssue({
      body: formBody({ os: '_No response_' }),
      created_at: HISTORICAL,
    }),
    expected: { close: false, reason: 'historical' },
  },
  {
    name: 'historical issue 40 style report is not closed',
    issue: {
      title: '请求增加投屏功能',
      body: '',
      labels: [],
      created_at: HISTORICAL,
    },
    expected: { close: false, reason: 'historical' },
  },
  {
    name: 'pull request payload is ignored',
    issue: bugIssue({
      body: '',
      pull_request: { url: 'https://example.invalid/pr/1' },
    }),
    expected: { close: false, reason: 'pull_request' },
  },
];

for (const testCase of cases) {
  const decision = decideBugIssueAction({
    issue: testCase.issue,
    effectiveAt: BUG_REPORT_RULES_EFFECTIVE_AT,
  });
  if (testCase.expected) {
    assert.strictEqual(decision.close, testCase.expected.close, testCase.name);
    assert.strictEqual(decision.reason, testCase.expected.reason, testCase.name);
  } else {
    assert.strictEqual(decision.close, testCase.close, testCase.name);
    assert.strictEqual(decision.reason, 'missing_fields', testCase.name);
    const missing = testCase.missing;
    const expected = Array.isArray(missing) ? missing : [missing];
    for (const field of expected) {
      assert.ok(
        (decision.missing || []).includes(field),
        `${testCase.name} should miss ${field}, got ${JSON.stringify(decision)}`,
      );
    }
  }
}

assert.ok(Date.parse(BUG_REPORT_RULES_EFFECTIVE_AT) > Date.parse(HISTORICAL));
console.log(`ok ${cases.length} cases`);
