/// The relay's REST side: project workspaces in the cloud and the git
/// repositories attached to them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class Repo {
  final String name;
  final String url;
  final String branch;
  const Repo({required this.name, required this.url, this.branch = ''});

  Map<String, dynamic> toJson() => {'name': name, 'url': url, 'branch': branch};

  factory Repo.fromJson(Map<String, dynamic> j) =>
      Repo(name: j['name'] ?? '', url: j['url'] ?? '', branch: j['branch'] ?? '');
}

class Workspace {
  /// The project's folder on the cloud host; Muse sessions start here.
  final String root;
  final List<Repo> repos;
  const Workspace(this.root, this.repos);
}

class RelayException implements Exception {
  final String message;
  const RelayException(this.message);
  @override
  String toString() => message;
}

abstract class RelayApi {
  Future<Workspace> ensureProject(String projectId);
  Future<List<Repo>> attachRepo(String projectId, String url, {String? branch});
  Future<List<Repo>> detachRepo(String projectId, String name);
  Future<void> deleteProject(String projectId);
}

class HttpRelayApi implements RelayApi {
  final Uri base;
  final String token;
  final http.Client _http;

  HttpRelayApi(this.base, this.token, {http.Client? client}) : _http = client ?? http.Client();

  Uri _u(String path) => base.replace(path: '${base.path.replaceAll(RegExp(r'/$'), '')}$path');

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Future<Map<String, dynamic>> _call(String method, String path, [Object? body]) async {
    final req = http.Request(method, _u(path))..headers.addAll(_headers);
    if (body != null) req.body = jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req));
    } catch (e) {
      throw RelayException('Could not reach the relay at $base ($e).');
    }
    Map<String, dynamic> j;
    try {
      j = (jsonDecode(res.body) as Map).cast<String, dynamic>();
    } catch (_) {
      j = {};
    }
    if (res.statusCode == 401) {
      throw const RelayException('The relay refused the token. Check the relay token in Settings.');
    }
    if (res.statusCode >= 400) throw RelayException('${j['error'] ?? 'The relay answered ${res.statusCode}.'}');
    return j;
  }

  static List<Repo> _repos(Object? list) =>
      [for (final r in (list as List? ?? [])) Repo.fromJson((r as Map).cast<String, dynamic>())];

  @override
  Future<Workspace> ensureProject(String projectId) async {
    final j = await _call('POST', '/projects', {'id': projectId});
    return Workspace(j['root'] as String, _repos(j['repos']));
  }

  @override
  Future<List<Repo>> attachRepo(String projectId, String url, {String? branch}) async {
    final j = await _call('POST', '/projects/$projectId/repos', {
      'url': url,
      if (branch != null && branch.isNotEmpty) 'branch': branch,
    });
    return _repos(j['repos']);
  }

  @override
  Future<List<Repo>> detachRepo(String projectId, String name) async =>
      _repos((await _call('DELETE', '/projects/$projectId/repos/${Uri.encodeComponent(name)}'))['repos']);

  @override
  Future<void> deleteProject(String projectId) => _call('DELETE', '/projects/$projectId');
}
