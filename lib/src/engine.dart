/// Connects projects to Muse on the cloud host: each project's main thread
/// is a Muse session whose agent orchestrates, the subagents it starts
/// become worker threads, and approvals come back to the user here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'host/host.dart';
import 'model.dart';
import 'msp.dart';
import 'relay_api.dart';

typedef TransportFactory = Future<MspTransport> Function(Uri relay, String token);
typedef RelayApiFactory = RelayApi Function(Uri relay, String token);

enum Connection { offline, connecting, online }

/// Sent ahead of a project's first message, so the agent hands work out
/// instead of doing it all in one thread. The user sees only their text.
const orchestratorBrief = '''You are the orchestrator of a Muse Code project. Plan the work, then start a subagent for each independent piece with a clear objective so they run in parallel; the user watches each subagent as its own thread. Keep this thread for planning, decisions and summaries. When subagents finish, check their results and tell the user what changed. Each folder in the workspace is a git repository attached to this project.

The user's request:''';

class MuseController extends ChangeNotifier {
  final Host host;
  final TransportFactory _openTransport;
  final RelayApiFactory _makeApi;

  Settings settings = Settings();
  final List<Project> projects = [];
  String? selectedProjectId;
  final Map<String, String> _selectedThread = {};
  bool loaded = false;

  Connection connection = Connection.offline;
  String? connectionError;
  MspClient? _msp;
  bool _wantOnline = false;
  Timer? _retry;
  int _retryDelay = 2;

  final Map<String, Future<void>> _sessionStarts = {};
  Timer? _saveTimer;

  MuseController({required this.host, TransportFactory? transport, RelayApiFactory? relayApi})
      : _openTransport = transport ?? WebSocketTransport.connect,
        _makeApi = relayApi ?? ((uri, token) => HttpRelayApi(uri, token));

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

  bool get online => connection == Connection.online;

  /// The Muse host's name and version, once connected.
  String? get hostLabel {
    final info = _msp?.serverInfo?['serverInfo'];
    if (info is! Map) return null;
    return '${info['name']} ${info['version']}';
  }

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
    if (settings.configured) unawaited(connect());
  }

  String encodeState() => jsonEncode({
        'version': 2,
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

  @override
  void dispose() {
    _retry?.cancel();
    _saveTimer?.cancel();
    unawaited(_msp?.close());
    super.dispose();
  }

  // ---- Connection ----------------------------------------------------

  Uri? get _relayUri {
    final u = Uri.tryParse(settings.relayUrl.trim());
    return u == null || !u.hasScheme || u.host.isEmpty ? null : u;
  }

  RelayApi _api() {
    final u = _relayUri;
    if (u == null || !settings.configured) {
      throw const RelayException('Add the relay URL and relay token in Settings first.');
    }
    return _makeApi(u, settings.relayToken.trim());
  }

  Future<void> connect() async {
    if (connection == Connection.connecting) return;
    _retry?.cancel();
    final uri = _relayUri;
    if (!settings.configured || uri == null) {
      connectionError = 'Add the relay URL and relay token in Settings to connect to Muse.';
      notifyListeners();
      return;
    }
    _wantOnline = true;
    final old = _msp;
    _msp = null;
    if (old != null) await old.close();
    connection = Connection.connecting;
    connectionError = null;
    notifyListeners();

    try {
      final transport = await _openTransport(uri, settings.relayToken.trim());
      final msp = MspClient(transport)..onServerRequest = _onServerRequest;
      msp.notifications.listen(_onNotification);
      unawaited(msp.closed.then((_) => _onClosed(msp)));
      await msp.initialize().timeout(const Duration(seconds: 30));
      _msp = msp;
      connection = Connection.online;
      _retryDelay = 2;
      notifyListeners();
      for (final p in projects) {
        if (p.sessionId != null) unawaited(_resume(p));
      }
    } catch (e) {
      connection = Connection.offline;
      connectionError = 'Could not connect to the relay: $e';
      notifyListeners();
      _scheduleRetry();
    }
  }

  Future<void> disconnect() async {
    _wantOnline = false;
    _retry?.cancel();
    final msp = _msp;
    _msp = null;
    connection = Connection.offline;
    notifyListeners();
    await msp?.close();
  }

  void _onClosed(MspClient msp) {
    if (!identical(_msp, msp)) return;
    _msp = null;
    connection = Connection.offline;
    connectionError = 'Lost the connection to the relay. Reconnecting…';
    notifyListeners();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_wantOnline) return;
    _retry?.cancel();
    _retry = Timer(Duration(seconds: _retryDelay), () => unawaited(connect()));
    _retryDelay = min(_retryDelay * 2, 30);
  }

  MspClient _requireOnline() {
    final msp = _msp;
    if (msp == null) throw const MspError(MspError.disconnected, 'Not connected to Muse. Check Settings.');
    return msp;
  }

  /// Picks a project's session back up after a (re)connect and replays
  /// what happened while the app was away.
  Future<void> _resume(Project p) async {
    final msp = _msp;
    if (msp == null) return;
    final main = p.main;
    try {
      final r = await msp.command('session/resume', {'sessionId': p.sessionId});
      final s = (r['session'] as Map?)?.cast<String, dynamic>() ?? {};
      if (s['status'] == 'running') {
        main.status = ThreadStatus.running;
        main.activeTurnId = s['activeTurnId'] as String? ?? main.activeTurnId;
      } else if (main.isBusy) {
        main.status = ThreadStatus.idle;
      }
      _changed();
    } catch (e) {
      main.entries.add(Entry(kind: EntryKind.notice, text: 'Could not resume this project\'s Muse session: $e'));
      _changed();
      return;
    }
    await _subscribe(p.sessionId!, main);
    for (final w in p.workers) {
      if (w.childSessionId != null) await _subscribe(w.childSessionId!, w);
    }
  }

  Future<void> _subscribe(String sessionId, ChatThread t) async {
    final msp = _msp;
    if (msp == null) return;
    try {
      await msp.request('view/subscribe', {
        'sessionId': sessionId,
        if (t.viewCursor != null) 'after': t.viewCursor,
      });
    } catch (e) {
      // A worker whose child session can't be followed still shows its
      // objective and result.
      debugPrint('view/subscribe $sessionId: $e');
    }
  }

  // ---- Projects and repos --------------------------------------------

  /// A new, empty project. Its cloud workspace is made right away when the
  /// relay is set up, otherwise before its first message.
  Project createProject(String name) {
    final p = Project(name: name.trim().isEmpty ? 'Untitled' : name.trim());
    projects.add(p);
    selectedProjectId = p.id;
    _changed();
    if (settings.configured) {
      unawaited(_ensureWorkspace(p).catchError((Object e) {
        p.main.entries.add(Entry(kind: EntryKind.notice, text: 'Could not create the cloud workspace: $e'));
        _changed();
      }));
    }
    return p;
  }

  void renameProject(Project p, String name) {
    if (name.trim().isEmpty) return;
    p.name = name.trim();
    _changed();
  }

  Future<void> _ensureWorkspace(Project p) async {
    if (p.root != null) return;
    final ws = await _api().ensureProject(p.id);
    p.root = ws.root;
    p.repos
      ..clear()
      ..addAll(ws.repos);
    _changed();
  }

  /// Clones [url] into the project's workspace. Throws with a message for
  /// the user when the relay or git refuses.
  Future<void> attachRepo(Project p, String url, {String? branch}) async {
    await _ensureWorkspace(p);
    final repos = await _api().attachRepo(p.id, url.trim(), branch: branch);
    p.repos
      ..clear()
      ..addAll(repos);
    final added = repos.where((r) => r.url == url.trim()).firstOrNull;
    p.main.entries.add(Entry(kind: EntryKind.notice, text: 'Attached ${added?.name ?? url.trim()}.'));
    _changed();
  }

  Future<void> detachRepo(Project p, Repo repo) async {
    final repos = await _api().detachRepo(p.id, repo.name);
    p.repos
      ..clear()
      ..addAll(repos);
    p.main.entries.add(Entry(kind: EntryKind.notice, text: 'Detached ${repo.name}.'));
    _changed();
  }

  /// Removes the project here and its workspace in the cloud.
  void deleteProject(Project p) {
    projects.remove(p);
    if (selectedProjectId == p.id) selectedProjectId = projects.isEmpty ? null : projects.first.id;
    _changed();
    if (p.root != null && settings.configured) {
      unawaited(_api().deleteProject(p.id).catchError((Object e) => debugPrint('delete ${p.id}: $e')));
    }
  }

  void deleteWorker(Project p, ChatThread t) {
    if (t.isMain) return;
    p.threads.remove(t);
    if (_selectedThread[p.id] == t.id) _selectedThread.remove(p.id);
    _changed();
    final msp = _msp;
    if (msp != null && p.sessionId != null && t.subagentId != null) {
      unawaited(msp
          .command('subagent/close', {'sessionId': p.sessionId, 'subagentId': t.subagentId})
          .catchError((Object e) => <String, dynamic>{}));
    }
  }

  Future<void> setAutoApprove(Project p, bool value) async {
    p.autoApprove = value;
    _changed();
    final msp = _msp;
    if (msp != null && p.sessionId != null) {
      try {
        await msp.command('session/setApprovalMode', {
          'sessionId': p.sessionId,
          'mode': value ? 'allowAll' : 'promptUnmatched',
        });
      } catch (e) {
        p.main.entries.add(Entry(kind: EntryKind.notice, text: 'Could not change the approval mode: $e'));
        _changed();
      }
    }
    if (value) {
      for (final t in p.threads) {
        for (final e in t.entries) {
          if (e.approval != null && !e.approval!.deciding) _autoDecide(p, e);
        }
      }
    }
  }

  void updateSettings(void Function(Settings s) edit) {
    final before = (settings.relayUrl, settings.relayToken);
    edit(settings);
    _changed();
    if (before != (settings.relayUrl, settings.relayToken)) {
      if (settings.configured) {
        unawaited(connect());
      } else {
        unawaited(disconnect());
      }
    }
  }

  // ---- Sending -------------------------------------------------------

  Future<void> _ensureSession(Project p) {
    if (p.sessionId != null) return Future.value();
    return _sessionStarts[p.id] ??= () async {
      try {
        await _ensureWorkspace(p);
        final r = await _requireOnline().command('session/start', {
          'workspaceRoot': p.root,
          'approvalMode': p.autoApprove ? 'allowAll' : 'promptUnmatched',
        });
        p.sessionId = (r['session'] as Map)['sessionId'] as String;
        p.main.viewCursor = r['viewCursor'] as String?;
        _changed();
      } finally {
        _sessionStarts.remove(p.id);
      }
    }();
  }

  /// The user typed [text] into [t]: a new turn for the orchestrator, or a
  /// message straight to a worker.
  Future<void> sendUserMessage(Project p, ChatThread t, String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    final commandId = uuidv7();
    final first = t.isMain && !t.entries.any((e) => e.kind == EntryKind.user);
    final entry = Entry(kind: EntryKind.user, text: text, commandId: commandId);
    t.entries.add(entry);
    _changed();
    try {
      final msp = _requireOnline();
      if (t.isMain) {
        await _ensureSession(p);
        final r = await msp.request('turn/start', {
          'sessionId': p.sessionId,
          'commandId': commandId,
          'input': [
            {'type': 'text', 'text': first ? '$orchestratorBrief\n\n$text' : text},
          ],
          'displayText': text,
          'ifBusy': 'queue',
        });
        t.activeTurnId = r['turnId'] as String? ?? t.activeTurnId;
        if (!t.isBusy) t.status = ThreadStatus.running;
      } else {
        if (p.sessionId == null || t.subagentId == null) {
          throw StateError('This worker is no longer part of a Muse session.');
        }
        await msp.request('subagent/sendMessage', {
          'sessionId': p.sessionId,
          'commandId': commandId,
          'subagentId': t.subagentId,
          'body': text,
        });
      }
    } catch (e) {
      t.entries.add(Entry(kind: EntryKind.notice, text: 'Not sent: ${e is StateError ? e.message : e}'));
    }
    _changed();
  }

  Future<void> stop(Project p, ChatThread t) async {
    try {
      final msp = _requireOnline();
      if (t.isMain) {
        await msp.command('turn/interrupt', {
          'sessionId': p.sessionId,
          if (t.activeTurnId != null) 'turnId': t.activeTurnId,
        });
      } else {
        await msp.command('subagent/interrupt', {'sessionId': p.sessionId, 'subagentId': t.subagentId});
      }
    } catch (e) {
      t.entries.add(Entry(kind: EntryKind.notice, text: 'Could not stop: $e'));
      _changed();
    }
  }

  // ---- Approvals -----------------------------------------------------

  Future<void> decide(Project p, Entry e, String choiceId) async {
    final a = e.approval;
    if (a == null || a.deciding) return;
    a.deciding = true;
    _changed();
    try {
      await _requireOnline().command('approval/decide', {
        'sessionId': a.sessionId,
        'approvalId': a.approvalId,
        'requirementId': a.requirementId,
        'choiceId': choiceId,
      });
    } catch (err) {
      a.deciding = false;
      e.output = 'Could not send the decision: $err';
      _changed();
    }
  }

  void _autoDecide(Project p, Entry e) {
    final choices = e.approval!.choices;
    Map<String, dynamic>? pick(bool Function(Map<String, dynamic>) f) => choices.where(f).firstOrNull;
    final choice = pick((c) => c['scope'] == 'session' && '${c['decision']}'.startsWith('approved')) ??
        pick((c) => '${c['decision']}'.startsWith('approved'));
    if (choice != null) unawaited(decide(p, e, choice['choiceId'] as String));
  }

  FutureOr<Map<String, dynamic>> _onServerRequest(String method, Map<String, dynamic> params) {
    if (method == 'approval/request') {
      _attachApproval(params);
      return const {};
    }
    throw MspError(-32601, 'Muse Code does not handle $method yet.');
  }

  void _attachApproval(Map<String, dynamic> params) {
    final loc = _locate(params['sessionId'] as String?);
    if (loc == null) return;
    final (p, t) = loc;
    final approvalId = params['approvalId'] as String;
    final itemId = params['itemId'] as String?;
    var e = (itemId == null ? null : t.entry(itemId)) ??
        t.entries.where((x) => x.approval?.approvalId == approvalId).firstOrNull;
    if (e == null) {
      e = Entry(
        id: itemId ?? 'approval-$approvalId',
        kind: EntryKind.tool,
        toolName: params['toolName'] as String? ?? 'tool',
        input: parseArgs(params['rawArgs']),
      );
      t.entries.add(e);
    }
    if (e.approval?.approvalId == approvalId) return;
    e.approval = Approval(
      approvalId: approvalId,
      sessionId: params['sessionId'] as String,
      requirementId: (params['currentRequirementId'] as Map?)?.cast<String, dynamic>() ??
          {'approvalId': approvalId, 'sourceIndex': 0},
      choices: [for (final c in (params['availableChoices'] as List? ?? [])) (c as Map).cast<String, dynamic>()],
      subject: _describeSubject(params['subject']),
    );
    e.toolState = ToolState.awaitingApproval;
    t.status = ThreadStatus.waiting;
    _changed();
    if (p.autoApprove) _autoDecide(p, e);
  }

  static String? _describeSubject(Object? s) {
    if (s is! Map) return null;
    if (s['kind'] == 'fileAccess') return '${s['access'] ?? 'access'} ${s['path'] ?? ''}'.trim();
    if (s['command'] is String) return s['command'] as String;
    return null;
  }

  // ---- Events from the host ----------------------------------------

  (Project, ChatThread)? _locate(String? sessionId) {
    if (sessionId == null) return null;
    for (final p in projects) {
      if (p.sessionId == sessionId) return (p, p.main);
      final w = p.workerFor(childSessionId: sessionId);
      if (w != null) return (p, w);
    }
    return null;
  }

  void _onNotification((String, Map<String, dynamic>) event) {
    final (method, params) = event;
    final loc = _locate(params['sessionId'] as String?);
    if (loc == null) return;
    final (p, t) = loc;

    final cursor = params['viewCursor'];
    if (cursor is String) {
      final seq = cursorSeq(cursor);
      final have = cursorSeq(t.viewCursor);
      if (seq != null && have != null && seq <= have) return;
      t.viewCursor = cursor;
    }

    switch (method) {
      case 'turn/started':
        t.status = ThreadStatus.running;
        if (t.isMain) t.activeTurnId = params['turnId'] as String?;
      case 'turn/completed':
        _turnCompleted(t, params);
      case 'item/started' || 'item/updated' || 'item/completed':
        final item = (params['item'] as Map?)?.cast<String, dynamic>();
        if (item != null) _upsertItem(p, t, item);
      case 'item/delta':
        final e = t.entry(params['itemId'] as String? ?? '');
        final delta = params['delta'] as String? ?? '';
        if (e == null) return;
        if (e.kind == EntryKind.tool) {
          e.output = (e.output ?? '') + delta;
        } else {
          e.text += delta;
        }
      case 'approval/requested':
        _attachApproval(params);
        return;
      case 'approval/resolved':
        _approvalResolved(t, params);
      case 'view/gap':
        t.entries.add(Entry(kind: EntryKind.notice, text: 'Some updates were missed while reconnecting.'));
      default:
        return;
    }
    _changed();
  }

  void _turnCompleted(ChatThread t, Map<String, dynamic> params) {
    final usage = params['usage'];
    if (usage is Map) {
      t.inputTokens += (usage['inputTokens'] as num? ?? 0).toInt();
      t.outputTokens += (usage['outputTokens'] as num? ?? 0).toInt();
    }
    for (final e in t.entries) {
      if (e.approval != null) {
        e.approval = null;
        e.toolState = ToolState.denied;
      }
    }
    final terminal = params['terminal'] as String? ?? 'completed';
    switch (terminal) {
      case 'failed':
        final error = params['error'];
        final message = error is Map ? error['message'] : null;
        t.entries.add(Entry(kind: EntryKind.notice, text: 'The turn failed${message == null ? '.' : ': $message'}'));
        t.status = ThreadStatus.error;
      case 'cancelled':
        t.entries.add(Entry(kind: EntryKind.notice, text: 'Stopped.'));
        t.status = ThreadStatus.stopped;
      default:
        t.status = t.isMain ? ThreadStatus.idle : ThreadStatus.done;
    }
    if (t.isMain) t.activeTurnId = null;
  }

  void _approvalResolved(ChatThread t, Map<String, dynamic> params) {
    final id = params['approvalId'];
    for (final e in t.entries) {
      if (e.approval?.approvalId != id) continue;
      e.approval = null;
      final decision = '${params['decision'] ?? ''}';
      e.toolState = decision.startsWith('approved') ? ToolState.running : ToolState.denied;
    }
    if (t.status == ThreadStatus.waiting && !t.entries.any((e) => e.approval != null)) {
      t.status = ThreadStatus.running;
    }
  }

  static ToolState _toolState(Object? status) => switch (status) {
        'completed' => ToolState.done,
        'failed' || 'timedOut' => ToolState.error,
        'rejected' || 'cancelled' => ToolState.denied,
        _ => ToolState.running,
      };

  void _upsertItem(Project p, ChatThread t, Map<String, dynamic> item) {
    final id = item['itemId'] as String? ?? '';
    final status = item['status'];
    switch (item['kind']) {
      case 'userMessage':
        final commandId = item['commandId'];
        final text = (item['displayText'] ?? item['text'] ?? '') as String;
        final e = t.entry(id) ??
            t.entries.where((x) => x.commandId != null && x.commandId == commandId).firstOrNull ??
            t.entries
                .where((x) => x.kind == EntryKind.user && x.commandId != null && x.text.trim() == text.trim())
                .firstOrNull;
        if (e != null) {
          e
            ..id = id
            ..commandId = null;
        } else {
          t.entries.add(Entry(id: id, kind: t.isMain ? EntryKind.user : EntryKind.assigned, text: text));
        }
      case 'agentMessage':
        var e = t.entry(id);
        if (e == null) {
          e = Entry(id: id, kind: EntryKind.assistant);
          t.entries.add(e);
        }
        final text = item['text'] as String? ?? '';
        if (text.isNotEmpty || status == 'completed') e.text = text;
      case 'toolCall':
        var e = t.entry(id);
        if (e == null) {
          e = Entry(id: id, kind: EntryKind.tool);
          t.entries.add(e);
        }
        e.toolName = item['tool'] as String? ?? e.toolName ?? 'tool';
        e.input = parseArgs(item['args']) ?? e.input;
        e.output = (item['visibleOutput'] ?? item['output'] ?? e.output) as String?;
        e.toolState = e.approval != null && status == 'inProgress' ? ToolState.awaitingApproval : _toolState(status);
      case 'subagent':
        _upsertSubagent(p, t, item);
      case 'reasoning' || 'reminderChild':
        break;
      case 'compaction':
        if (t.entry(id) == null) {
          t.entries.add(Entry(id: id, kind: EntryKind.notice, text: 'Muse compacted the conversation to save context.'));
        }
      default:
        final text = item['fallbackText'] as String?;
        if (text == null || text.isEmpty) return;
        final e = t.entry(id);
        if (e == null) {
          t.entries.add(Entry(id: id, kind: EntryKind.notice, text: text));
        } else {
          e.text = text;
        }
    }
  }

  static String _title(String objective) {
    var s = objective.trim().split('\n').first;
    if (s.length > 48) s = '${s.substring(0, 47).trimRight()}…';
    return s.isEmpty ? 'Worker' : s[0].toUpperCase() + s.substring(1);
  }

  /// A subagent the agent started: its own worker thread, a card in the
  /// thread that started it, and its result reported back there.
  void _upsertSubagent(Project p, ChatThread parent, Map<String, dynamic> item) {
    final itemId = item['itemId'] as String;
    final subagentId = item['subagentId'] as String? ?? itemId;
    final objective = (item['objective'] ?? item['fallbackText'] ?? 'Subagent') as String;
    var w = p.workerFor(subagentId: subagentId);
    if (w == null) {
      w = ChatThread(kind: ThreadKind.worker, title: _title(objective), subagentId: subagentId, status: ThreadStatus.running);
      w.entries.add(Entry(kind: EntryKind.assigned, text: objective));
      p.threads.add(w);
    }
    final child = item['childSessionId'] as String?;
    if (child != null && w.childSessionId != child) {
      w.childSessionId = child;
      unawaited(_subscribe(child, w));
    }

    final status = item['status'];
    final control = item['controlStatus'];
    final result = (item['result'] as Map?)?.cast<String, dynamic>();
    final failed = status == 'failed' || result?['errorKind'] != null;
    if (status == 'cancelled') {
      w.status = ThreadStatus.stopped;
    } else if (failed) {
      w.status = ThreadStatus.error;
    } else if (status == 'completed' || control == 'resultReady' || control == 'closed') {
      w.status = ThreadStatus.done;
    } else if (w.status != ThreadStatus.waiting) {
      w.status = ThreadStatus.running;
    }

    var card = parent.entry(itemId);
    if (card == null) {
      card = Entry(id: itemId, kind: EntryKind.tool, toolName: 'subagent', workerId: w.id);
      parent.entries.add(card);
    }
    card.input = {'objective': objective, if (item['agentPath'] != null) 'agent': item['agentPath']};
    card.toolState = switch (w.status) {
      ThreadStatus.done => ToolState.done,
      ThreadStatus.error => ToolState.error,
      ThreadStatus.stopped => ToolState.denied,
      _ => ToolState.running,
    };

    if (result != null && parent.entry('report-$itemId') == null) {
      final summary = (result['summary'] as String? ?? '').trim();
      final text = (result['text'] as String? ?? '').trim();
      final body = [
        if (failed) 'Failed (${result['errorKind'] ?? 'error'}).',
        if (summary.isNotEmpty) summary,
        if (text.isNotEmpty && text != summary) text,
      ].join('\n\n');
      parent.entries.add(Entry(
        id: 'report-$itemId',
        kind: EntryKind.report,
        workerId: w.id,
        text: body.isEmpty ? 'Finished without a written result.' : body,
      ));
    }
  }
}
