/// Runs the threads: the orchestrator's loop in each project's main
/// thread, the workers it spawns, tool calls and approvals, and saving.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'anthropic.dart';
import 'host/host.dart';
import 'model.dart';
import 'tools.dart';

typedef ClientFactory = LlmClient Function(String apiKey);

class MuseController extends ChangeNotifier {
  final Host host;
  final ClientFactory _clientFactory;

  Settings settings = Settings();
  final List<Project> projects = [];
  String? selectedProjectId;
  final Map<String, String> _selectedThread = {};

  final Map<String, CancelToken> _cancels = {};
  final Map<String, Completer<bool>> _approvals = {};
  Timer? _saveTimer;
  bool loaded = false;

  MuseController({required this.host, ClientFactory? clientFactory})
      : _clientFactory = clientFactory ?? ((key) => AnthropicClient(apiKey: key));

  // ---- Selection -----------------------------------------------------

  Project? get project {
    for (final p in projects) {
      if (p.id == selectedProjectId) return p;
    }
    return projects.isEmpty ? null : projects.first;
  }

  ChatThread? get thread {
    final p = project;
    if (p == null) return null;
    return p.thread(_selectedThread[p.id] ?? '') ?? p.main;
  }

  void selectProject(String id) {
    selectedProjectId = id;
    notifyListeners();
    _scheduleSave();
  }

  void selectThread(String threadId) {
    final p = project;
    if (p == null) return;
    _selectedThread[p.id] = threadId;
    notifyListeners();
  }

  String get apiKey => settings.apiKey.isNotEmpty ? settings.apiKey : (host.envApiKey ?? '');

  // ---- Persistence ---------------------------------------------------

  Future<void> load() async {
    try {
      final raw = await host.loadState();
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        settings = Settings.fromJson((j['settings'] as Map? ?? {}).cast<String, dynamic>());
        projects
          ..clear()
          ..addAll([for (final p in (j['projects'] as List? ?? [])) Project.fromJson((p as Map).cast())]);
        selectedProjectId = j['selectedProjectId'] as String?;
      }
    } catch (e) {
      debugPrint('Could not load saved state: $e');
    }
    loaded = true;
    notifyListeners();
  }

  String encodeState() => jsonEncode({
        'version': 1,
        'settings': settings.toJson(),
        'selectedProjectId': selectedProjectId,
        'projects': [for (final p in projects) p.toJson()],
      });

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), saveNow);
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    try {
      await host.saveState(encodeState());
    } catch (e) {
      debugPrint('Could not save state: $e');
    }
  }

  void _changed() {
    notifyListeners();
    _scheduleSave();
  }

  // ---- Projects and settings ----------------------------------------

  Project createProject(String name, String root) {
    final p = Project(name: name.trim().isEmpty ? 'Untitled' : name.trim(), root: root.trim());
    projects.add(p);
    selectedProjectId = p.id;
    _changed();
    return p;
  }

  void updateProject(Project p, {String? name, String? root, bool? autoApprove}) {
    if (name != null && name.trim().isNotEmpty) p.name = name.trim();
    if (root != null) p.root = root.trim();
    if (autoApprove != null) p.autoApprove = autoApprove;
    _changed();
  }

  void deleteProject(Project p) {
    for (final t in p.threads) {
      stop(t);
    }
    projects.remove(p);
    if (selectedProjectId == p.id) selectedProjectId = projects.isEmpty ? null : projects.first.id;
    _changed();
  }

  void deleteWorker(Project p, ChatThread t) {
    if (t.isMain) return;
    stop(t);
    p.threads.remove(t);
    if (_selectedThread[p.id] == t.id) _selectedThread.remove(p.id);
    _changed();
  }

  void updateSettings(void Function(Settings s) edit) {
    edit(settings);
    _changed();
  }

  // ---- Sending -------------------------------------------------------

  /// The user typed [text] into [t].
  void sendUserMessage(Project p, ChatThread t, String text) {
    text = text.trim();
    if (text.isEmpty) return;
    t.entries.add(Entry(kind: EntryKind.user, text: text));
    if (!t.isMain) {
      // A direct message isn't the orchestrator's request, so its report
      // waits for the orchestrator's next turn instead of waking it.
      t.reportToOrchestrator = false;
    }
    _deliver(p, t, text);
  }

  /// Queues [text] as the next user turn of [t] and runs the thread
  /// unless it's already running (it picks the message up when its turn
  /// ends) or [wake] is false.
  void _deliver(Project p, ChatThread t, String text, {bool wake = true}) {
    t.inbox.add(text);
    _changed();
    if (wake && !t.isBusy) unawaited(_run(p, t));
  }

  void stop(ChatThread t) {
    _cancels[t.id]?.cancel();
  }

  void resolveApproval(Project p, Entry e, {required bool allow, bool always = false}) {
    if (always) p.autoApprove = true;
    _approvals.remove(e.id)?.complete(allow);
    _changed();
  }

  bool isAwaitingApproval(Entry e) => _approvals.containsKey(e.id);

  // ---- The agent loop ------------------------------------------------

  Future<void> _run(Project p, ChatThread t) async {
    if (t.isBusy) return;
    final cancel = CancelToken();
    _cancels[t.id] = cancel;
    t.status = ThreadStatus.running;
    _changed();

    var outcome = ThreadStatus.done;
    String? error;
    try {
      while (t.inbox.isNotEmpty && !cancel.isCancelled) {
        _appendUser(t, [
          for (final m in t.inbox) {'type': 'text', 'text': m}
        ]);
        t.inbox.clear();
        await _loop(p, t, cancel);
      }
      if (cancel.isCancelled) outcome = ThreadStatus.stopped;
    } on CancelledException {
      outcome = ThreadStatus.stopped;
    } catch (e) {
      outcome = ThreadStatus.error;
      error = e.toString();
    } finally {
      _cancels.remove(t.id);
      t.liveText = '';
    }

    if (outcome == ThreadStatus.stopped) {
      t.entries.add(Entry(kind: EntryKind.notice, text: 'Stopped.'));
    } else if (outcome == ThreadStatus.error) {
      t.entries.add(Entry(kind: EntryKind.notice, text: error!));
    }
    t.status = t.isMain && outcome == ThreadStatus.done ? ThreadStatus.idle : outcome;
    _changed();

    if (!t.isMain && outcome != ThreadStatus.stopped) _report(p, t, outcome, error);

    // Messages that arrived after the last check.
    if (t.inbox.isNotEmpty && outcome == ThreadStatus.done) unawaited(_run(p, t));
  }

  void _appendUser(ChatThread t, List<Map<String, dynamic>> content) {
    if (t.history.isNotEmpty && t.history.last['role'] == 'user') {
      // A stop mid-response leaves the last user turn unanswered; add to it.
      final last = t.history.last;
      final existing = last['content'];
      last['content'] = [
        if (existing is String) {'type': 'text', 'text': existing} else ...(existing as List),
        ...content,
      ];
    } else {
      t.history.add({'role': 'user', 'content': content});
    }
  }

  Future<void> _loop(Project p, ChatThread t, CancelToken cancel) async {
    final key = apiKey;
    if (key.isEmpty) {
      throw ApiException('Add your Anthropic API key in Settings (an x-api-key, starting sk-ant-) to start.');
    }
    final client = _clientFactory(key);
    final files = host.hasFiles && host.directoryExists(p.root);
    final tools = t.isMain ? orchestratorTools(files: files) : workerTools(files: files);
    final system = t.isMain
        ? orchestratorPrompt(project: p.name, root: files ? p.root : '')
        : workerPrompt(project: p.name, root: files ? p.root : '', title: t.title);

    while (true) {
      cancel.throwIfCancelled();
      t.liveText = '';
      final turn = await client.send(
        model: t.isMain ? settings.model : settings.workerModel,
        effort: settings.effort,
        system: system,
        messages: t.history,
        tools: tools,
        cancel: cancel,
        onText: (d) {
          t.liveText += d;
          notifyListeners();
        },
      );
      t.liveText = '';
      t.inputTokens += turn.inputTokens;
      t.outputTokens += turn.outputTokens;
      t.history.add({'role': 'assistant', 'content': turn.content});

      for (final block in turn.content) {
        if (block['type'] == 'text' && (block['text'] as String? ?? '').trim().isNotEmpty) {
          t.entries.add(Entry(kind: EntryKind.assistant, text: (block['text'] as String).trim()));
        }
      }
      if (turn.stopReason == 'refusal') {
        t.entries.add(Entry(kind: EntryKind.notice, text: 'Claude declined to continue this request.'));
      } else if (turn.stopReason == 'max_tokens' && turn.toolUses.isEmpty) {
        t.entries.add(Entry(kind: EntryKind.notice, text: 'The reply hit the length limit.'));
      }
      _changed();

      final uses = turn.toolUses;
      if (uses.isEmpty) return;

      final entries = [
        for (final u in uses)
          Entry(
            kind: EntryKind.tool,
            toolName: u['name'] as String,
            toolUseId: u['id'] as String,
            input: (u['input'] as Map).cast<String, dynamic>(),
            toolState: ToolState.pending,
          )
      ];
      t.entries.addAll(entries);
      _changed();

      // Parallel calls run together; all results go back in one message.
      final results = await Future.wait([
        for (final e in entries) _runTool(p, t, e, cancel),
      ]);
      t.history.add({
        'role': 'user',
        'content': [
          for (final (i, r) in results.indexed)
            {
              'type': 'tool_result',
              'tool_use_id': entries[i].toolUseId,
              'content': r.output,
              if (r.isError) 'is_error': true,
            }
        ],
      });
      _changed();
      cancel.throwIfCancelled();
      if (turn.stopReason == 'refusal') return;
    }
  }

  Future<ToolResult> _runTool(Project p, ChatThread t, Entry e, CancelToken cancel) async {
    final name = e.toolName!;
    final input = e.input!;
    ToolResult result;
    if (input.containsKey('_invalid_json')) {
      result = const ToolResult.error('The tool input was not valid JSON (it may have been cut off). Try again.');
    } else if (cancel.isCancelled) {
      result = const ToolResult.error('Stopped by the user before this ran.');
    } else if (orchestrationTools.contains(name)) {
      result = _orchestrate(p, t, e);
    } else {
      if (mutatingTools.contains(name) && !p.autoApprove) {
        e.toolState = ToolState.awaitingApproval;
        t.status = ThreadStatus.waiting;
        final completer = Completer<bool>();
        _approvals[e.id] = completer;
        final unregister = cancel.onCancel(() {
          if (!completer.isCompleted) completer.complete(false);
          _approvals.remove(e.id);
        });
        _changed();
        final allowed = await completer.future;
        unregister();
        if (t.status == ThreadStatus.waiting && !t.entries.any((x) => _approvals.containsKey(x.id))) {
          t.status = ThreadStatus.running;
        }
        if (!allowed) {
          e.toolState = ToolState.denied;
          e.output = cancel.isCancelled ? 'Stopped.' : 'Denied.';
          _changed();
          return ToolResult.error(cancel.isCancelled
              ? 'Stopped by the user.'
              : 'The user denied this action. Ask them or take another approach.');
        }
      }
      e.toolState = ToolState.running;
      _changed();
      result = await host.runTool(name, input, root: p.root, cancel: cancel);
    }
    e.output = result.output;
    e.toolState = result.isError ? ToolState.error : ToolState.done;
    _changed();
    return result;
  }

  ToolResult _orchestrate(Project p, ChatThread main, Entry e) {
    final input = e.input!;
    switch (e.toolName) {
      case 'spawn_worker':
        final title = (input['title'] as String? ?? '').trim();
        final instructions = (input['instructions'] as String? ?? '').trim();
        if (instructions.isEmpty) return const ToolResult.error('instructions is empty.');
        p.workerCount++;
        final worker = ChatThread(
          kind: ThreadKind.worker,
          title: title.isEmpty ? 'Worker ${p.workerCount}' : title,
          reportToOrchestrator: true,
        );
        p.threads.add(worker);
        e.workerId = worker.id;
        worker.entries.add(Entry(kind: EntryKind.assigned, text: instructions));
        _deliver(p, worker, instructions);
        return ToolResult('Started worker ${worker.id} ("${worker.title}"). Its report will arrive as a '
            '<worker_report> message.');
      case 'message_worker':
        final w = p.thread(input['worker_id'] as String? ?? '');
        if (w == null || w.isMain) {
          return ToolResult.error('No worker with id ${input['worker_id']}. Use list_workers.');
        }
        final message = (input['message'] as String? ?? '').trim();
        if (message.isEmpty) return const ToolResult.error('message is empty.');
        e.workerId = w.id;
        w.reportToOrchestrator = true;
        w.entries.add(Entry(kind: EntryKind.assigned, text: message));
        _deliver(p, w, message);
        return ToolResult(w.isBusy
            ? 'Queued for ${w.id}; it reads it when its current step finishes.'
            : 'Sent to ${w.id}.');
      case 'list_workers':
        if (p.workers.isEmpty) return const ToolResult('No workers yet.');
        return ToolResult([for (final w in p.workers) '${w.id}  ${w.status.name}  ${w.title}'].join('\n'));
    }
    return ToolResult.error('Unknown tool ${e.toolName}');
  }

  /// Hands a worker's outcome to the main thread: a card the user sees, and
  /// a message the orchestrator reads.
  void _report(Project p, ChatThread w, ThreadStatus outcome, String? error) {
    if (!p.threads.contains(w)) return;
    final text = outcome == ThreadStatus.error
        ? 'Failed: $error'
        : (_lastAssistantText(w) ?? 'Finished without a written report.');
    final main = p.main;
    main.entries.add(Entry(kind: EntryKind.report, text: text, workerId: w.id));
    final status = outcome == ThreadStatus.error ? 'failed' : 'finished';
    final message = '<worker_report worker_id="${w.id}" title="${w.title}" status="$status">\n$text\n</worker_report>';
    _deliver(p, main, message, wake: w.reportToOrchestrator);
    w.reportToOrchestrator = false;
  }

  String? _lastAssistantText(ChatThread t) {
    for (final e in t.entries.reversed) {
      if (e.kind == EntryKind.assistant) return e.text;
      if (e.kind == EntryKind.user || e.kind == EntryKind.assigned) return null;
    }
    return null;
  }
}
