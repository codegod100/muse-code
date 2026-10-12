/// The cloud side of Muse Code: a small HTTP server that keeps each
/// project's workspace, clones the git repos attached to it, and bridges
/// the app's WebSocket to a `muse serve` host speaking the Muse Session
/// Protocol (MSP) over stdio. Nothing runs on the user's machine.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class RelayConfig {
  /// Every request must carry this, as `Authorization: Bearer <token>` or,
  /// for the WebSocket (browsers can't set headers there), as the
  /// `bearer.<token>` subprotocol.
  final String token;

  /// The `muse` binary. It reads META_API_KEY from this process's
  /// environment.
  final String museBin;

  /// Where project workspaces live, one folder per project.
  final String workspaces;

  /// Optional, for cloning private GitHub repos.
  final String? githubToken;

  /// Extra environment for the muse host, for tests.
  final Map<String, String> museEnv;

  const RelayConfig({
    required this.token,
    this.museBin = 'muse',
    this.workspaces = '/workspaces',
    this.githubToken,
    this.museEnv = const {},
  });

  factory RelayConfig.fromEnvironment(Map<String, String> env) {
    final token = env['MUSE_RELAY_TOKEN'] ?? '';
    if (token.length < 16) {
      throw StateError('Set MUSE_RELAY_TOKEN to a random secret of at least 16 characters.');
    }
    final gh = env['GITHUB_TOKEN'];
    return RelayConfig(
      token: token,
      museBin: env['MUSE_BIN'] ?? 'muse',
      workspaces: env['MUSE_WORKSPACES'] ?? '/workspaces',
      githubToken: gh == null || gh.isEmpty ? null : gh,
    );
  }
}

final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _repoNamePattern = RegExp(r'^[A-Za-z0-9._-]{1,100}$');

/// Guidance the orchestrating agent reads from the project folder.
const agentsMd = '''# Muse Code project

You are the orchestrator for this project. Plan the work, then hand each
independent piece to a subagent with a clear objective so the pieces run in
parallel. Keep the user's thread for planning, decisions and summaries; let
subagents do the reading, editing and running. When subagents report back,
check their results and tell the user what changed.

Each folder here is a git repository attached to the project.
''';

class Relay {
  final RelayConfig config;
  HttpServer? _server;
  _Bridge? _bridge;

  Relay(this.config);

  int get port => _server!.port;

  Future<void> start({int port = 8080, InternetAddress? address}) async {
    await Directory(config.workspaces).create(recursive: true);
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _server!.listen((req) => unawaited(_handle(req)));
  }

  Future<void> close() async {
    await _bridge?.stop();
    await _server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
      ..set('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS');
    try {
      if (req.method == 'OPTIONS') {
        res.statusCode = HttpStatus.noContent;
        await res.close();
        return;
      }
      final path = req.uri.pathSegments;
      if (path.length == 1 && path[0] == 'health') {
        return _json(res, {'ok': true});
      }
      if (!_authorized(req)) {
        return _json(res, {'error': 'Send Authorization: Bearer <MUSE_RELAY_TOKEN>.'},
            status: HttpStatus.unauthorized);
      }
      if (path.length == 1 && path[0] == 'msp' && WebSocketTransformer.isUpgradeRequest(req)) {
        return await _openBridge(req);
      }
      if (path.isNotEmpty && path[0] == 'projects') {
        return await _projects(req, path.sublist(1));
      }
      _json(res, {'error': 'Not found.'}, status: HttpStatus.notFound);
    } on _HttpError catch (e) {
      _json(res, {'error': e.message}, status: e.status);
    } catch (e) {
      stderr.writeln('relay: ${req.method} ${req.uri.path} failed: $e');
      _json(res, {'error': 'Internal error.'}, status: HttpStatus.internalServerError);
    }
  }

  bool _authorized(HttpRequest req) {
    final header = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (header.startsWith('Bearer ') && _same(header.substring(7).trim(), config.token)) return true;
    final protocols = req.headers['sec-websocket-protocol'] ?? const [];
    for (final line in protocols) {
      for (final p in line.split(',')) {
        final v = p.trim();
        if (v.startsWith('bearer.') && _same(v.substring(7), config.token)) return true;
      }
    }
    return false;
  }

  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  // ---- Projects and repos -------------------------------------------

  String _root(String id) => '${config.workspaces}/$id';

  Future<void> _projects(HttpRequest req, List<String> path) async {
    final res = req.response;
    if (path.isEmpty && req.method == 'POST') {
      final body = await _body(req);
      final id = body['id'];
      if (id is! String || !_idPattern.hasMatch(id)) throw _HttpError(400, 'id must match ${_idPattern.pattern}.');
      final dir = Directory(_root(id));
      await dir.create(recursive: true);
      final agents = File('${dir.path}/AGENTS.md');
      if (!await agents.exists()) await agents.writeAsString(agentsMd);
      return _json(res, {'root': dir.path, 'repos': await _repos(id)});
    }
    if (path.isEmpty) throw _HttpError(405, 'Use POST /projects.');
    final id = path[0];
    if (!_idPattern.hasMatch(id) || !await Directory(_root(id)).exists()) {
      throw _HttpError(404, 'No project $id.');
    }
    if (path.length == 1 && req.method == 'GET') {
      return _json(res, {'root': _root(id), 'repos': await _repos(id)});
    }
    if (path.length == 1 && req.method == 'DELETE') {
      await Directory(_root(id)).delete(recursive: true);
      return _json(res, {'ok': true});
    }
    if (path.length == 2 && path[1] == 'repos') {
      if (req.method == 'GET') return _json(res, {'repos': await _repos(id)});
      if (req.method == 'POST') {
        final body = await _body(req);
        final repo = await _clone(id, body['url'], body['branch']);
        return _json(res, {'repo': repo, 'repos': await _repos(id)});
      }
    }
    if (path.length == 3 && path[1] == 'repos' && req.method == 'DELETE') {
      final name = path[2];
      if (!_repoNamePattern.hasMatch(name) || name.startsWith('.')) throw _HttpError(400, 'Bad repo name.');
      final dir = Directory('${_root(id)}/$name');
      if (!await dir.exists()) throw _HttpError(404, 'No repo $name.');
      await dir.delete(recursive: true);
      return _json(res, {'repos': await _repos(id)});
    }
    throw _HttpError(404, 'Not found.');
  }

  Future<List<Map<String, dynamic>>> _repos(String id) async {
    final out = <Map<String, dynamic>>[];
    await for (final e in Directory(_root(id)).list()) {
      if (e is! Directory || !await Directory('${e.path}/.git').exists()) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      out.add({
        'name': name,
        'path': e.path,
        'url': _scrub(await _git(['remote', 'get-url', 'origin'], cwd: e.path)),
        'branch': await _git(['rev-parse', '--abbrev-ref', 'HEAD'], cwd: e.path),
      });
    }
    out.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    return out;
  }

  Future<Map<String, dynamic>> _clone(String id, Object? url, Object? branch) async {
    if (url is! String || url.trim().isEmpty) throw _HttpError(400, 'Send {"url": "https://github.com/owner/repo"}.');
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw _HttpError(400, 'Use an https git URL without credentials in it.');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) throw _HttpError(400, 'That URL names no repository.');
    var name = segments.last;
    if (name.endsWith('.git')) name = name.substring(0, name.length - 4);
    if (!_repoNamePattern.hasMatch(name) || name.startsWith('.')) throw _HttpError(400, 'Bad repository name $name.');
    final dest = '${_root(id)}/$name';
    if (await Directory(dest).exists()) throw _HttpError(409, '$name is already attached.');
    final args = <String>[
      if (config.githubToken != null && uri.host == 'github.com') ...[
        '-c',
        'http.https://github.com/.extraheader=AUTHORIZATION: basic '
            '${base64.encode(utf8.encode('x-access-token:${config.githubToken}'))}',
      ],
      'clone',
      if (branch is String && branch.trim().isNotEmpty) ...['--branch', branch.trim()],
      '--',
      uri.toString(),
      dest,
    ];
    final r = await Process.run('git', args, environment: {'GIT_TERMINAL_PROMPT': '0'});
    if (r.exitCode != 0) {
      throw _HttpError(422, 'git clone failed: ${_scrub('${r.stderr}'.trim())}');
    }
    return {
      'name': name,
      'path': dest,
      'url': uri.toString(),
      'branch': await _git(['rev-parse', '--abbrev-ref', 'HEAD'], cwd: dest),
    };
  }

  String _scrub(String s) {
    final t = config.githubToken;
    return t == null ? s : s.replaceAll(t, '***');
  }

  static Future<String> _git(List<String> args, {required String cwd}) async {
    final r = await Process.run('git', args, workingDirectory: cwd);
    return r.exitCode == 0 ? '${r.stdout}'.trim() : '';
  }

  // ---- The MSP bridge ----------------------------------------------

  Future<void> _openBridge(HttpRequest req) async {
    // One host at a time: a new connection (the app reconnecting) replaces
    // the old one, so a session's lease is never held by a stale host.
    await _bridge?.stop();
    final ws = await WebSocketTransformer.upgrade(req,
        protocolSelector: (protocols) => protocols.contains('msp') ? 'msp' : protocols.first);
    final Process process;
    try {
      process = await Process.start(config.museBin, ['serve'],
          workingDirectory: config.workspaces, environment: config.museEnv);
    } catch (e) {
      stderr.writeln('relay: could not start ${config.museBin}: $e');
      await ws.close(WebSocketStatus.internalServerError, 'Could not start the Muse host.');
      return;
    }
    _bridge = _Bridge(ws, process);
  }

  static Future<Map<String, dynamic>> _body(HttpRequest req) async {
    try {
      final text = await utf8.decodeStream(req);
      final j = jsonDecode(text.isEmpty ? '{}' : text);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    throw _HttpError(400, 'Send a JSON object.');
  }

  static void _json(HttpResponse res, Object body, {int status = 200}) {
    res
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    unawaited(res.close());
  }
}

class _HttpError implements Exception {
  final int status;
  final String message;
  _HttpError(this.status, this.message);
}

/// One app connection piped to one `muse serve` process: each WebSocket
/// text message is one MSP frame written to stdin, each stdout line one
/// frame sent back.
class _Bridge {
  final WebSocket ws;
  final Process process;
  bool _stopped = false;

  _Bridge(this.ws, this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.isNotEmpty && ws.readyState == WebSocket.open) ws.add(line);
    });
    process.stderr.transform(utf8.decoder).listen((chunk) => stderr.write('muse: $chunk'));
    ws.listen(
      (frame) {
        if (frame is String) process.stdin.writeln(frame.replaceAll('\n', ''));
      },
      onDone: () => unawaited(stop()),
      onError: (_) => unawaited(stop()),
    );
    unawaited(process.exitCode.then((code) {
      if (ws.readyState == WebSocket.open) {
        ws.close(code == 0 ? WebSocketStatus.normalClosure : WebSocketStatus.internalServerError,
            'Muse host exited ($code).');
      }
    }));
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    // EOF on stdin is the host's shutdown signal; it drains, then exits.
    try {
      await process.stdin.close();
    } catch (_) {}
    final exited = await process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      process.kill();
      return -1;
    });
    if (exited == -1) {
      await process.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
    if (ws.readyState == WebSocket.open) await ws.close();
  }
}
