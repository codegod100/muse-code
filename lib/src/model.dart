/// Projects, threads and what the transcript shows, with JSON round-trips
/// for keeping them between runs. The work itself lives in Muse sessions on
/// the cloud host; this is the app's view of it.
library;

import 'dart:convert';
import 'dart:math';

import 'relay_api.dart';

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

  /// The objective a worker was started with.
  assigned,

  /// Assistant prose.
  assistant,

  /// A tool call, with its output once it ran. Subagent starts are shown
  /// this way too, with `toolName` 'subagent'.
  tool,

  /// A worker's result, shown in the main thread.
  report,

  /// A system line: errors, stops, gaps.
  notice,
}

enum ToolState { pending, awaitingApproval, running, done, error, denied }

/// A pending Muse approval and the choices the host offers for it.
class Approval {
  final String approvalId;
  final String sessionId;
  final Map<String, dynamic> requirementId;

  /// `{choiceId, label, decision, scope}` from the host.
  final List<Map<String, dynamic>> choices;
  final String? subject;

  /// A decision was sent and the host hasn't confirmed it yet.
  bool deciding = false;

  Approval({
    required this.approvalId,
    required this.sessionId,
    required this.requirementId,
    required this.choices,
    this.subject,
  });
}

class Entry {
  String id;
  final EntryKind kind;
  String text;
  final DateTime at;

  // Tool calls.
  String? toolName;
  Map<String, dynamic>? input;
  String? output;
  ToolState? toolState;

  /// The worker thread a subagent start or report refers to.
  String? workerId;

  /// The `commandId` a user message was sent with, until the host echoes it.
  String? commandId;

  /// Set while the host waits for the user's decision; not saved.
  Approval? approval;

  Entry({
    String? id,
    required this.kind,
    this.text = '',
    DateTime? at,
    this.toolName,
    this.input,
    this.output,
    this.toolState,
    this.workerId,
    this.commandId,
  })  : id = id ?? newId('e'),
        at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'text': text,
        'at': at.toIso8601String(),
        if (toolName != null) 'toolName': toolName,
        if (input != null) 'input': input,
        if (output != null) 'output': output,
        if (toolState != null) 'toolState': toolState!.name,
        if (workerId != null) 'workerId': workerId,
        if (commandId != null) 'commandId': commandId,
      };

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'],
        kind: EntryKind.values.byName(j['kind']),
        text: j['text'] ?? '',
        at: DateTime.tryParse(j['at'] ?? ''),
        toolName: j['toolName'],
        input: (j['input'] as Map?)?.cast<String, dynamic>(),
        output: j['output'],
        toolState: j['toolState'] == null ? null : ToolState.values.byName(j['toolState']),
        workerId: j['workerId'],
        commandId: j['commandId'],
      );
}

/// Tool arguments arrive as a JSON string; anything else is kept as text.
Map<String, dynamic>? parseArgs(Object? args) {
  if (args is Map) return args.cast<String, dynamic>();
  if (args is! String || args.isEmpty) return null;
  try {
    final j = jsonDecode(args);
    if (j is Map) return j.cast<String, dynamic>();
  } catch (_) {}
  return {'args': args};
}

class ChatThread {
  final String id;
  final ThreadKind kind;
  String title;
  ThreadStatus status;
  final DateTime createdAt;

  /// What the transcript shows.
  final List<Entry> entries;

  /// Workers are Muse subagents of the main session: the durable id the
  /// host uses for control, and the child session that streams their work.
  String? subagentId;
  String? childSessionId;

  /// The last view event applied (`v:<session>:<n>`), so replays after a
  /// reconnect skip what is already here.
  String? viewCursor;

  /// The main session's running turn, for Stop.
  String? activeTurnId;

  int inputTokens;
  int outputTokens;

  ChatThread({
    String? id,
    required this.kind,
    required this.title,
    this.status = ThreadStatus.idle,
    DateTime? createdAt,
    List<Entry>? entries,
    this.subagentId,
    this.childSessionId,
    this.viewCursor,
    this.activeTurnId,
    this.inputTokens = 0,
    this.outputTokens = 0,
  })  : id = id ?? newId('t'),
        createdAt = createdAt ?? DateTime.now(),
        entries = entries ?? [];

  bool get isMain => kind == ThreadKind.orchestrator;
  bool get isBusy => status == ThreadStatus.running || status == ThreadStatus.waiting;

  Entry? entry(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'status': status.name,
        'createdAt': createdAt.toIso8601String(),
        'entries': [for (final e in entries) e.toJson()],
        if (subagentId != null) 'subagentId': subagentId,
        if (childSessionId != null) 'childSessionId': childSessionId,
        if (viewCursor != null) 'viewCursor': viewCursor,
        if (activeTurnId != null) 'activeTurnId': activeTurnId,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
      };

  factory ChatThread.fromJson(Map<String, dynamic> j) => ChatThread(
        id: j['id'],
        kind: ThreadKind.values.byName(j['kind']),
        title: j['title'] ?? '',
        // The host is the source of truth; resuming the session corrects this.
        status: ThreadStatus.values.byName(j['status'] ?? 'idle'),
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        entries: [
          for (final e in (j['entries'] as List? ?? [])) Entry.fromJson((e as Map).cast<String, dynamic>())
        ],
        subagentId: j['subagentId'],
        childSessionId: j['childSessionId'],
        viewCursor: j['viewCursor'],
        activeTurnId: j['activeTurnId'],
        inputTokens: j['inputTokens'] ?? 0,
        outputTokens: j['outputTokens'] ?? 0,
      );
}

/// A project stands on its own: it's created from a name, and git
/// repositories are attached to it afterwards.
class Project {
  final String id;
  String name;

  /// The project's folder on the cloud host, once the relay made it.
  String? root;

  /// Repositories cloned into [root].
  final List<Repo> repos;

  /// The Muse session behind the main thread.
  String? sessionId;

  /// Let Muse edit files and run commands without asking.
  bool autoApprove;

  final List<ChatThread> threads;
  final DateTime createdAt;

  Project({
    String? id,
    required this.name,
    this.root,
    List<Repo>? repos,
    this.sessionId,
    this.autoApprove = false,
    List<ChatThread>? threads,
    DateTime? createdAt,
  })  : id = id ?? newId('p'),
        repos = repos ?? [],
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

  ChatThread? workerFor({String? subagentId, String? childSessionId}) {
    for (final t in workers) {
      if (subagentId != null && t.subagentId == subagentId) return t;
      if (childSessionId != null && t.childSessionId == childSessionId) return t;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (root != null) 'root': root,
        'repos': [for (final r in repos) r.toJson()],
        if (sessionId != null) 'sessionId': sessionId,
        'autoApprove': autoApprove,
        'createdAt': createdAt.toIso8601String(),
        'threads': [for (final t in threads) t.toJson()],
      };

  factory Project.fromJson(Map<String, dynamic> j) => Project(
        id: j['id'],
        name: j['name'] ?? 'Project',
        root: j['root'],
        repos: [for (final r in (j['repos'] as List? ?? [])) Repo.fromJson((r as Map).cast<String, dynamic>())],
        sessionId: j['sessionId'],
        autoApprove: j['autoApprove'] ?? false,
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        threads: [
          for (final t in (j['threads'] as List? ?? [])) ChatThread.fromJson((t as Map).cast<String, dynamic>())
        ],
      );
}

class Settings {
  /// The Muse relay, e.g. https://muse-relay.example.com.
  String relayUrl;

  /// The relay's MUSE_RELAY_TOKEN, sent as `Authorization: Bearer <token>`.
  String relayToken;

  /// 'system', 'light' or 'dark'.
  String theme;

  Settings({this.relayUrl = '', this.relayToken = '', this.theme = 'system'});

  bool get configured => relayUrl.trim().isNotEmpty && relayToken.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {'relayUrl': relayUrl, 'relayToken': relayToken, 'theme': theme};

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        relayUrl: j['relayUrl'] ?? '',
        relayToken: j['relayToken'] ?? '',
        theme: j['theme'] ?? 'system',
      );
}
