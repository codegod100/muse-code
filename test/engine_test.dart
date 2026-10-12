import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_code/src/anthropic.dart';
import 'package:muse_code/src/engine.dart';
import 'package:muse_code/src/host/host_io.dart';
import 'package:muse_code/src/model.dart';

import 'fake_llm.dart';

Future<void> until(bool Function() done, {String? reason}) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting${reason == null ? '' : ' for $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Orchestrator spawns one worker; the worker writes a file and reports.
AssistantTurnScript orchestrated() => (system, messages) {
      final last = lastUserText(messages);
      if (system.contains('You are the orchestrator')) {
        if (last.contains('<worker_report worker_id')) return text('The worker added hello.txt.');
        if (last.startsWith('RESULT:')) return text('Started a worker on it.');
        return toolCall('spawn_worker', {'title': 'Write hello', 'instructions': 'Create hello.txt containing hi'});
      }
      if (last.startsWith('RESULT:')) return text('Created hello.txt containing "hi".');
      return toolCall('write_file', {'path': 'hello.txt', 'content': 'hi\n'});
    };

typedef AssistantTurnScript = Script;

void main() {
  late Directory tmp;
  late Directory root;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('muse_test');
    root = Directory('${tmp.path}/proj')..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  MuseController make(FakeLlm llm) {
    final c = MuseController(host: IoHost(statePath: '${tmp.path}/state.json'), clientFactory: (_) => llm);
    c.settings.apiKey = 'sk-ant-test';
    c.loaded = true;
    return c;
  }

  test('the orchestrator spawns a worker, which works and reports back', () async {
    final llm = FakeLlm(orchestrated());
    final c = make(llm);
    final p = c.createProject('Demo', root.path)..autoApprove = true;

    c.sendUserMessage(p, p.main, 'Make a hello file');
    await until(() => p.main.entries.any((e) => e.text == 'The worker added hello.txt.'), reason: 'final reply');

    expect(File('${root.path}/hello.txt').readAsStringSync(), 'hi\n');
    final worker = p.workers.single;
    expect(worker.title, 'Write hello');
    expect(worker.status, ThreadStatus.done);
    expect(p.main.status, ThreadStatus.idle);

    // The worker got the instructions, not the user's words, and has the
    // worker tool set.
    final workerReq = llm.requests.firstWhere((r) => r.system.contains('You are a worker'));
    expect(lastUserText(workerReq.messages), 'Create hello.txt containing hi');
    expect(workerReq.tools, containsAll(['write_file', 'edit_file', 'run_command']));
    expect(workerReq.tools, isNot(contains('spawn_worker')));

    // The main thread shows the spawn, the report card, and the summary.
    final kinds = p.main.entries.map((e) => e.kind).toList();
    expect(kinds, [EntryKind.user, EntryKind.tool, EntryKind.assistant, EntryKind.report, EntryKind.assistant]);
    expect(p.main.entries[3].workerId, worker.id);
    expect(p.main.entries[3].text, 'Created hello.txt containing "hi".');

    // History alternates roles, with thinking blocks passed back intact.
    final roles = p.main.history.map((m) => m['role']).toList();
    for (var i = 1; i < roles.length; i++) {
      expect(roles[i], isNot(roles[i - 1]));
    }
    expect((p.main.history[1]['content'] as List).first['type'], 'tool_use');

    // State survives a save and load.
    await c.saveNow();
    final again = MuseController(host: IoHost(statePath: '${tmp.path}/state.json'));
    await again.load();
    expect(again.projects.single.threads.length, 2);
    expect(again.projects.single.main.entries.length, 5);
    expect(again.settings.apiKey, 'sk-ant-test');
  });

  test('edits wait for approval, and a denial goes back to the model', () async {
    final llm = FakeLlm((system, messages) {
      final last = lastUserText(messages);
      if (last.startsWith('RESULT:')) return text('Done: $last');
      return toolCall('run_command', {'command': 'echo hi > out.txt'});
    });
    final c = make(llm);
    final p = c.createProject('Demo', root.path);
    p.workerCount = 1;
    final w = ChatThread(kind: ThreadKind.worker, title: 'Run it');
    p.threads.add(w);

    c.sendUserMessage(p, w, 'run it');
    await until(() => w.status == ThreadStatus.waiting, reason: 'approval');
    final tool = w.entries.firstWhere((e) => e.kind == EntryKind.tool);
    expect(c.isAwaitingApproval(tool), isTrue);
    expect(File('${root.path}/out.txt').existsSync(), isFalse);

    c.resolveApproval(p, tool, allow: true);
    await until(() => w.status == ThreadStatus.done, reason: 'finish');
    expect(File('${root.path}/out.txt').readAsStringSync().trim(), 'hi');
    expect(tool.toolState, ToolState.done);

    // A direct message's report goes to Main without waking the orchestrator.
    expect(p.main.entries.single.kind, EntryKind.report);
    expect(p.main.inbox.single, contains('<worker_report'));
    expect(p.main.status, ThreadStatus.idle);

    c.sendUserMessage(p, w, 'again');
    await until(() => w.status == ThreadStatus.waiting);
    c.resolveApproval(p, w.entries.lastWhere((e) => e.kind == EntryKind.tool), allow: false);
    await until(() => w.status == ThreadStatus.done);
    expect(w.entries.last.text, contains('The user denied this action'));
  });

  test('stop cancels a waiting thread and leaves a valid history', () async {
    final llm = FakeLlm((system, messages) => toolCall('write_file', {'path': 'x', 'content': 'y'}));
    final c = make(llm);
    final p = c.createProject('Demo', root.path);
    final w = ChatThread(kind: ThreadKind.worker, title: 'W');
    p.threads.add(w);

    c.sendUserMessage(p, w, 'go');
    await until(() => w.status == ThreadStatus.waiting);
    c.stop(w);
    await until(() => w.status == ThreadStatus.stopped);
    expect(w.history.last['role'], 'user');
    expect((w.history.last['content'] as List).single['type'], 'tool_result');
    expect(File('${root.path}/x').existsSync(), isFalse);
  });

  test('tools stay inside the project folder', () async {
    final host = IoHost(statePath: '${tmp.path}/s.json');
    final r = await host.runTool('read_file', {'path': '../state.json'}, root: root.path, cancel: CancelToken());
    expect(r.isError, isTrue);
    expect(r.output, contains('outside the project folder'));

    await host.runTool('write_file', {'path': 'a/b.txt', 'content': 'one two one'}, root: root.path, cancel: CancelToken());
    final edit = await host.runTool('edit_file', {'path': 'a/b.txt', 'old_string': 'one', 'new_string': '1'},
        root: root.path, cancel: CancelToken());
    expect(edit.isError, isTrue);
    await host.runTool('edit_file', {'path': 'a/b.txt', 'old_string': 'one', 'new_string': '1', 'replace_all': true},
        root: root.path, cancel: CancelToken());
    expect(File('${root.path}/a/b.txt').readAsStringSync(), '1 two 1');

    final search = await host.runTool('search', {'pattern': 'two'}, root: root.path, cancel: CancelToken());
    expect(search.output, 'a/b.txt:1: 1 two 1');
    final list = await host.runTool('list_dir', {}, root: root.path, cancel: CancelToken());
    expect(list.output, 'a/');
  });
}
