// Run the actual inline workflow against an offline GitHub API double.
// Ruby/Psych supplies YAML parsing on macOS without adding a package dependency.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { resolve } = require('node:path');
const vm = require('node:vm');

const workflow = JSON.parse(execFileSync('ruby', ['-ryaml', '-rjson', '-e',
  'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))',
  resolve(__dirname, '../workflows/auto-issue-key.yml')], { encoding: 'utf8' }));
const job = workflow.jobs['assign-key'];
const steps = job.steps;

async function run(options = {}) {
  const issue = { number: 906, title: 'Broken map', labels: [], ...options.issue };
  const payload = {
    action: options.action || 'created', issue,
    comment: { body: options.body ?? '/key', user: { login: 'comment-author' },
      author_association: options.association || 'NONE' },
  };
  if (options.noIssue) delete payload.issue;
  if (options.noAuthor) delete payload.comment.user;
  const calls = [];
  const writes = [];
  const comments = options.comments || [];
  const github = {
    rest: {
      repos: {
        getCollaboratorPermissionLevel: async (args) => {
          calls.push(args);
          if (options.error) throw new Error('permission lookup failed');
          return { data: options.permissionData ?? { permission: options.permission || 'read' } };
        },
      },
      issues: {
        update: async (args) => { writes.push(['title', args]); issue.title = args.title; },
        get: async () => ({ data: issue }),
        listComments: () => {},
        createComment: async (args) => { writes.push(['create', args]); },
        updateComment: async (args) => { writes.push(['update', args]); },
      },
    },
    paginate: { iterator: async function* () {
      // Separate pages ensure the existing comment need not be on the first page.
      yield { data: [] };
      yield { data: comments };
    } },
  };
  const context = {
    eventName: options.event || 'issue_comment', payload,
    repo: { owner: 'example', repo: 'project' },
    actor: 'admin-rerunning-the-job',
  };
  let error;
  try {
    for (const step of steps) {
      assert.ok(step.with?.script, 'Privileged workflow must only execute inline scripts');
      await vm.runInNewContext(`(async () => {\n${step.with.script}\n})()`, {
        github, context, process: { env: job.env }, core: { info() {} },
      });
    }
  } catch (caught) { error = caught; }
  return { calls, writes, error };
}

for (const permission of ['none', 'read', 'triage', 'unknown']) {
  for (const body of ['/key', '/branch feature']) {
    test(`${permission} cannot execute ${body}, even with MEMBER association`, async () => {
      const result = await run({ permission, body, association: 'MEMBER' });
      assert.equal(result.error, undefined);
      assert.equal(result.writes.length, 0);
      assert.equal(result.calls.length, 1);
      assert.equal(result.calls[0].username, 'comment-author');
    });
  }
}
for (const permission of ['write', 'admin']) {
  for (const body of ['/key', '/branch feature', '/branch TEST\r\n']) {
    test(`${permission} can execute ${JSON.stringify(body)} with NONE association`, async () => {
      const result = await run({ permission, body });
      assert.equal(result.error, undefined);
      assert.deepEqual(result.writes.map(([kind]) => kind), ['title', 'create']);
      assert.equal(result.writes[0][1].title, 'AIA-0906: Broken map');
      const prefix = body.includes('feature') ? 'feature' : body.includes('TEST') ? 'test' : 'fix';
      assert.ok(result.writes[1][1].body.includes(`${prefix}/AIA-0906/broken-map`));
    });
  }
}
for (const permissionData of [{}, { permission: null }, { permission: true }, { role_name: 'admin' }]) {
  test(`malformed permission response fails closed: ${JSON.stringify(permissionData)}`, async () => {
    assert.equal((await run({ permissionData })).writes.length, 0);
  });
}
test('permission lookup errors stop before all mutations', async () => {
  const result = await run({ error: true });
  assert.match(result.error.message, /permission lookup failed/);
  assert.equal(result.writes.length, 0);
});
for (const body of ['hello /key', '/keyboard', '/key extra', '/key\n/branch fix',
  '```\n/key\n```', ' /key', '/branch', '/branchfix', '/branch release',
  '/branch feature extra', '/branch feature\nhello', '/branch feature; echo bad']) {
  test(`ignores non-command ${JSON.stringify(body)}`, async () => {
    const result = await run({ body, permission: 'admin' });
    assert.equal(result.writes.length, 0);
    assert.equal(result.calls.length, 0);
  });
}
for (const options of [
  { issue: { pull_request: { url: 'https://example.test/pr/906' } } },
  { noIssue: true }, { noAuthor: true }, { action: 'edited' },
  { event: 'workflow_dispatch' }, { event: 'issues', action: 'closed' },
]) {
  test(`ignores unsupported payload ${JSON.stringify(options)}`, async () => {
    const result = await run({ permission: 'admin', ...options });
    assert.equal(result.error, undefined);
    assert.equal(result.writes.length, 0);
    assert.equal(result.calls.length, 0);
  });
}
for (const action of ['opened', 'labeled', 'unlabeled']) {
  test(`outside contributor ${action} issue still gets normalized and a label-based suggestion`, async () => {
    const result = await run({ event: 'issues', action, issue: { labels: ['feature'] } });
    assert.equal(result.error, undefined);
    assert.equal(result.calls.length, 0);
    assert.equal(result.writes[0][1].title, 'AIA-0906: Broken map');
    assert.ok(result.writes[1][1].body.includes('feature/AIA-0906/broken-map'));
  });
}
test('normalized titles still allow updating the existing bot suggestion', async () => {
  const result = await run({ permission: 'write', body: '/branch test',
    issue: { title: 'AIA-0906: Broken map' }, comments: [
      { id: 1, user: { type: 'User', login: 'outsider' }, body: '<!-- AIA_SHARE_BLOCK -->' },
      { id: 2, user: { type: 'Bot', login: 'github-actions[bot]' }, body: '<!-- AIA_SHARE_BLOCK -->' },
    ] });
  assert.equal(result.error, undefined);
  assert.deepEqual(result.writes.map(([kind]) => kind), ['update']);
  assert.equal(result.writes[0][1].comment_id, 2);
  assert.ok(result.writes[0][1].body.includes('test/AIA-0906/broken-map'));
});
test('a user-supplied marker cannot turn their comment into the bot comment', async () => {
  const result = await run({ event: 'issues', action: 'opened', comments: [
    { id: 1, user: { type: 'User', login: 'outsider' }, body: '<!-- AIA_SHARE_BLOCK -->' },
  ] });
  assert.equal(result.error, undefined);
  assert.deepEqual(result.writes.map(([kind]) => kind), ['title', 'create']);
});
test('identical bot suggestion does not create or update another comment', async () => {
  const first = await run({ permission: 'write' });
  const result = await run({ permission: 'write', issue: { title: 'AIA-0906: Broken map' },
    comments: [{ id: 2, user: { type: 'Bot', login: 'github-actions[bot]' }, body: first.writes[1][1].body }] });
  assert.equal(result.error, undefined);
  assert.equal(result.writes.length, 0);
});
test('workflow retains only issue write permission and no manual dispatch', () => {
  assert.deepEqual(workflow.permissions, { issues: 'write' });
  const triggers = workflow.on || workflow.true; // Psych uses YAML 1.1 boolean keys.
  assert.deepEqual(triggers, { issues: { types: ['opened', 'labeled', 'unlabeled'] },
    issue_comment: { types: ['created'] } });
  assert.ok(job.if.includes('!github.event.issue.pull_request'));
});
