/// Projects, threads and what the transcript shows, with JSON round-trips
/// for saving them between runs.
library;

import 'dart:math';

String newId([String prefix = '']) {
  final r = Random();
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final tail = List.generate(4, (_) => r.nextInt(36).toRadixString(36)).join();
  return '$prefix$stamp$tail';
}

enum ThreadKind { orchestrator, worker }

enum ThreadStatus { idle, running, waiting, done, error, stopped }

enum EntryKind {
  /// Something the user typed.
  user,

  /// A message the orchestrator sent a worker, shown in the worker thread.
  assigned,

  /// Assistant prose.
  assistant,

  /// A tool call, with its result once it ran.
  tool,

  /// A worker's final report, shown in the main thread.
  report,

  /// A system line: errors, stops, refusals.
  notice,
}

enum ToolState { pending, awaitingApproval, running, done, error, denied }

class Entry {
  final String id;
  final EntryKind kind;
  String text;
  final DateTime at;

  // Tool calls.
  String? toolName;
  String? toolUseId;
  Map<String, dynamic>? input;
  String? output;
  ToolState? toolState;

  /// The worker thread a spawn, message or report refers to.
  String? workerId;

  Entry({
    String? id,
    required this.kind,
    this.text = '',
    DateTime? at,
    this.toolName,
    this.toolUseId,
    this.input,
    this.output,
    this.toolState,
    this.workerId,
  })  : id = id ?? newId('e'),
        at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'text': text,
        'at': at.toIso8601String(),
        if (toolName != null) 'toolName': toolName,
        if (toolUseId != null) 'toolUseId': toolUseId,
        if (input != null) 'input': input,
        if (output != null) 'output': output,
        if (toolState != null) 'toolState': toolState!.name,
        if (workerId != null) 'workerId': workerId,
      };

  factory Entry.fromJson(Map<String, dynamic> j) {
    var state = j['toolState'] == null ? null : ToolState.values.byName(j['toolState']);
    // Anything mid-flight when the app closed didn't finish.
    if (state == ToolState.pending ||
        state == ToolState.running ||
        state == ToolState.awaitingApproval) {
      state = ToolState.error;
    }
    return Entry(
      id: j['id'],
      kind: EntryKind.values.byName(j['kind']),
      text: j['text'] ?? '',
      at: DateTime.tryParse(j['at'] ?? ''),
      toolName: j['toolName'],
      toolUseId: j['toolUseId'],
      input: (j['input'] as Map?)?.cast<String, dynamic>(),
      output: j['output'],
      toolState: state,
      workerId: j['workerId'],
    );
  }
}

class ChatThread {
  final String id;
  final ThreadKind kind;
  String title;
  ThreadStatus status;
  final DateTime createdAt;

  /// The conversation as sent to the API, append-only so thinking blocks
  /// stay valid when passed back.
  final List<Map<String, dynamic>> history;

  /// What the transcript shows.
  final List<Entry> entries;

  /// Messages waiting to be delivered as the next user turn.
  final List<String> inbox;

  /// Whether the orchestrator is waiting on this worker's report.
  bool reportToOrchestrator;

  int inputTokens;
  int outputTokens;

  /// Streaming text of the turn in progress; not saved.
  String liveText = '';

  ChatThread({
    String? id,
    required this.kind,
    required this.title,
    this.status = ThreadStatus.idle,
    DateTime? createdAt,
    List<Map<String, dynamic>>? history,
    List<Entry>? entries,
    List<String>? inbox,
    this.reportToOrchestrator = false,
    this.inputTokens = 0,
    this.outputTokens = 0,
  })  : id = id ?? newId('t'),
        createdAt = createdAt ?? DateTime.now(),
        history = history ?? [],
        entries = entries ?? [],
        inbox = inbox ?? [];

  bool get isMain => kind == ThreadKind.orchestrator;
  bool get isBusy => status == ThreadStatus.running || status == ThreadStatus.waiting;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'history': history,
        'entries': [for (final e in entries) e.toJson()],
        'inbox': inbox,
        'reportToOrchestrator': reportToOrchestrator,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
      };

  factory ChatThread.fromJson(Map<String, dynamic> j) {
    var status = ThreadStatus.values.byName(j['status'] ?? 'idle');
    if (status == ThreadStatus.running || status == ThreadStatus.waiting) {
      status = ThreadStatus.stopped;
    }
    final t = ChatThread(
      id: j['id'],
      kind: ThreadKind.values.byName(j['kind']),
      title: j['title'] ?? '',
      status: status,
      createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
      history: [for (final m in (j['history'] as List? ?? [])) (m as Map).cast<String, dynamic>()],
      entries: [
        for (final e in (j['entries'] as List? ?? [])) Entry.fromJson((e as Map).cast<String, dynamic>())
      ],
      inbox: [for (final s in (j['inbox'] as List? ?? [])) s as String],
      reportToOrchestrator: j['reportToOrchestrator'] ?? false,
      inputTokens: j['inputTokens'] ?? 0,
      outputTokens: j['outputTokens'] ?? 0,
    );
    t.repairHistory();
    return t;
  }

  /// Answers tool calls left without results (the app closed mid-turn), so
  /// the next request is valid.
  void repairHistory() {
    if (history.isEmpty) return;
    final last = history.last;
    if (last['role'] != 'assistant') return;
    final uses = (last['content'] as List).where((b) => b is Map && b['type'] == 'tool_use');
    if (uses.isEmpty) return;
    history.add({
      'role': 'user',
      'content': [
        for (final u in uses)
          {
            'type': 'tool_result',
            'tool_use_id': (u as Map)['id'],
            'content': 'Interrupted before this ran.',
            'is_error': true,
          }
      ],
    });
  }
}

class Project {
  final String id;
  String name;

  /// Folder the workers read, edit and run commands in. Empty means no
  /// folder: threads can talk but have no file tools.
  String root;

  /// Run edits and commands without asking.
  bool autoApprove;

  final List<ChatThread> threads;
  int workerCount;
  final DateTime createdAt;

  Project({
    String? id,
    required this.name,
    this.root = '',
    this.autoApprove = false,
    List<ChatThread>? threads,
    this.workerCount = 0,
    DateTime? createdAt,
  })  : id = id ?? newId('p'),
        createdAt = createdAt ?? DateTime.now(),
        threads = threads ?? [ChatThread(kind: ThreadKind.orchestrator, title: 'Main')];

  ChatThread get main => threads.firstWhere((t) => t.isMain);
  Iterable<ChatThread> get workers => threads.where((t) => !t.isMain);

  ChatThread? thread(String id) {
    for (final t in threads) {
      if (t.id == id) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'root': root,
        'autoApprove': autoApprove,
        'workerCount': workerCount,
        'createdAt': createdAt.toIso8601String(),
        'threads': [for (final t in threads) t.toJson()],
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'],
        name: j['name'] ?? 'Project',
        root: j['root'] ?? '',
        autoApprove: j['autoApprove'] ?? false,
        workerCount: j['workerCount'] ?? 0,
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        threads: [
          for (final t in (j['threads'] as List? ?? [])) ChatThread.fromJson((t as Map).cast<String, dynamic>())
        ],
      );
}

class Settings {
  String apiKey;
  String model;
  String workerModel;
  String effort;

  /// 'system', 'light' or 'dark'.
  String theme;

  Settings({
    this.apiKey = '',
    this.model = 'claude-opus-5-5',
    this.workerModel = 'claude-opus-5-5',
    this.effort = 'high',
    this.theme = 'system',
  });

  Map<String, dynamic> toJson() => {
        'apiKey': apiKey,
        'model': model,
        'workerModel': workerModel,
        'effort': effort,
        'theme': theme,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        apiKey: j['apiKey'] ?? '',
        model: j['model'] ?? 'claude-opus-5-5',
        workerModel: j['workerModel'] ?? 'claude-opus-5-5',
        effort: j['effort'] ?? 'high',
        theme: j['theme'] ?? 'system',
      );
}
