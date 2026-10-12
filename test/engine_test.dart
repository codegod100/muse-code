import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_code/src/engine.dart';
import 'package:muse_code/src/host/host_stub.dart';
import 'package:muse_code/src/model.dart';

import 'fake_muse.dart';

Future<(MuseController, TranscriptTransport, FakeRelayApi)> connected(String fixture, {String? state}) async {
  final transport = TranscriptTransport.fixture(fixture);
  final api = FakeRelayApi();
  final host = MemoryHost();
  final settings = {'relayUrl': 'https://relay.test', 'relayToken': 'token-0123456789abcdef'};
  await host.saveState(state ?? jsonEncode({'settings': settings, 'projects': []}));
  final c = MuseController(host: host, transport: (_, __) async => transport, relayApi: (_, __) => api);
  await c.load();
  await settle();
  return (c, transport, api);
}

void main() {
  test('a project is created from a name alone and gets a cloud workspace', () async {
    final (c, _, api) = await connected('text-run-single-turn');
    expect(c.online, isTrue);
    final p = c.createProject('Shop');
    await settle();
    expect(p.root, '/home/me/src/proj');
    expect(p.repos, isEmpty);
    expect(api.calls, ['ensure ${p.id}']);

    await c.attachRepo(p, 'https://github.com/acme/shop.git');
    expect(p.repos.single.name, 'shop');
    expect(p.main.entries.last.text, 'Attached shop.');
    await expectLater(c.attachRepo(p, 'git@github.com:acme/x'), throwsA(anything));
  });

  test('a message starts a Muse session and streams the answer into Main', () async {
    final (c, transport, _) = await connected('text-run-single-turn');
    final p = c.createProject('Agent');
    await c.sendUserMessage(p, p.main, 'Run the agent test suite and summarize failures');
    await settle();

    expect(transport.sentMethods, containsAllInOrder(['initialize', 'initialized', 'session/start', 'turn/start']));
    final turn = transport.sent.firstWhere((f) => f['method'] == 'turn/start')['params'] as Map;
    expect(turn['displayText'], 'Run the agent test suite and summarize failures');
    expect((turn['input'] as List).single['text'], startsWith(orchestratorBrief));

    expect(p.sessionId, '0198f0aa-1111-7000-8000-0000000000aa');
    final kinds = p.main.entries.map((e) => e.kind).toList();
    expect(kinds, [EntryKind.user, EntryKind.assistant]);
    expect(p.main.entries.first.text, 'Run the agent test suite and summarize failures');
    expect(p.main.entries.last.text, 'All 214 tests pass except two in tbh-agent...');
    expect(p.main.status, ThreadStatus.idle);
    expect(p.main.outputTokens, 1211);
  });

  test('approvals show the host\'s choices and send the one picked', () async {
    final (c, transport, _) = await connected('approval-round-trip');
    final p = c.createProject('Bump');
    await c.sendUserMessage(p, p.main, 'Update Cargo.toml to bump the version');
    await settle();

    final tool = p.main.entries.firstWhere((e) => e.kind == EntryKind.tool);
    expect(tool.toolName, 'write_file');
    expect(tool.toolState, ToolState.awaitingApproval);
    expect(tool.approval!.choices.map((x) => x['choiceId']), ['allow_once', 'allow_session', 'abort']);
    expect(tool.approval!.subject, 'write /home/me/src/proj/Cargo.toml');
    expect(p.main.status, ThreadStatus.waiting);

    await c.decide(p, tool, 'allow_session');
    await settle();
    final decide = transport.sent.firstWhere((f) => f['method'] == 'approval/decide')['params'] as Map;
    expect(decide['choiceId'], 'allow_session');
    expect(decide['requirementId'], {'approvalId': '0198f0ac-7777-7000-8000-0000000000e1', 'sourceIndex': 0});
    expect(tool.approval, isNull);
    expect(tool.toolState, ToolState.done);
    expect(tool.output, 'Cargo.toml updated\n');
    expect(p.main.status, ThreadStatus.idle);
  });

  test('Muse subagents become worker threads that report back to Main', () async {
    final project = Project(name: 'Tests', root: '/home/me/src/proj', sessionId: '018f7294-0000-7000-8000-7fed06700000');
    final state = jsonEncode({
      'settings': {'relayUrl': 'https://relay.test', 'relayToken': 'token-0123456789abcdef'},
      'projects': [project.toJson()],
    });
    final (c, transport, _) = await connected('subagent-nested-lifecycle', state: state);
    final p = c.projects.single;

    expect(transport.sentMethods, containsAllInOrder(['session/resume', 'view/subscribe']));
    final workers = p.workers.toList();
    expect(workers.map((w) => w.title), ['Survey the failing tests', 'Read the two candidate crates']);
    expect(workers[0].status, ThreadStatus.done);
    expect(workers[1].status, ThreadStatus.error);
    expect(workers.map((w) => w.childSessionId),
        ['018f7294-0000-7000-8000-7fed06700103', '018f7294-0000-7000-8000-7fed06700105']);
    expect(workers[0].entries.first.kind, EntryKind.assigned);

    final reports = p.main.entries.where((e) => e.kind == EntryKind.report).toList();
    expect(reports, hasLength(2));
    expect(reports.firstWhere((r) => r.workerId == workers[0].id).text, startsWith('two tbh-agent failures'));
    expect(reports.firstWhere((r) => r.workerId == workers[1].id).text, startsWith('Failed (provider_error)'));
    expect(p.main.entries.where((e) => e.toolName == 'subagent'), hasLength(2));

    // A message to a worker goes to its subagent.
    await c.sendUserMessage(p, workers[0], 'Also check the flaky one');
    final msg = transport.sent.lastWhere((f) => f['method'] == 'subagent/sendMessage')['params'] as Map;
    expect(msg['subagentId'], 'subagent-a');
    expect(msg['body'], 'Also check the flaky one');
  });

  test('state round-trips without the pending approvals', () async {
    final (c, _, _) = await connected('approval-round-trip');
    final p = c.createProject('Bump');
    await c.sendUserMessage(p, p.main, 'Update Cargo.toml to bump the version');
    await settle();
    final copy = Project.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(copy.sessionId, p.sessionId);
    expect(copy.main.viewCursor, p.main.viewCursor);
    expect(copy.main.entries.length, p.main.entries.length);
    expect(copy.main.entries.every((e) => e.approval == null), isTrue);
  });
}
