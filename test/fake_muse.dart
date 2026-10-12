import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:muse_code/src/msp.dart';
import 'package:muse_code/src/relay_api.dart';

/// A stand-in Muse host that replays a recorded MSP session. Each frame
/// the app sends is matched to the next unused client line with the same
/// method (or, for answers to the host's own requests, the next client
/// answer), and the host lines recorded after it are sent back, with
/// response ids rewritten to the app's. Requests the recording doesn't
/// have get an empty result.
class TranscriptTransport implements MspTransport {
  final List<({bool client, Map<String, dynamic> frame})> _lines;
  final _used = <int>{};
  final _incoming = StreamController<String>();
  final sent = <Map<String, dynamic>>[];

  TranscriptTransport(this._lines);

  factory TranscriptTransport.fixture(String name) {
    final lines = File('test/fixtures/msp/$name.ndjson').readAsLinesSync().where((l) => l.trim().isNotEmpty).map((l) {
      final j = jsonDecode(l) as Map<String, dynamic>;
      return (client: j['dir'] == 'client', frame: jsonDecode(j['raw'] as String) as Map<String, dynamic>);
    }).toList();
    return TranscriptTransport(lines);
  }

  Iterable<String> get sentMethods => sent.map((f) => f['method']).whereType<String>();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  void send(String frame) {
    final j = jsonDecode(frame) as Map<String, dynamic>;
    sent.add(j);
    final method = j['method'];
    var i = -1;
    for (var k = 0; k < _lines.length; k++) {
      final line = _lines[k];
      if (!line.client || _used.contains(k)) continue;
      if (line.frame['method'] == method) {
        i = k;
        break;
      }
    }
    if (i < 0) {
      if (method != null && j.containsKey('id')) {
        _emit({'jsonrpc': '2.0', 'id': j['id'], 'result': <String, dynamic>{}});
      }
      return;
    }
    _used.add(i);
    final recordedId = _lines[i].frame['id'];
    for (var k = i + 1; k < _lines.length && !_lines[k].client; k++) {
      _used.add(k);
      final out = Map<String, dynamic>.of(_lines[k].frame);
      if (!out.containsKey('method') && recordedId != null && out['id'] == recordedId) out['id'] = j['id'];
      _emit(out);
    }
  }

  void _emit(Map<String, dynamic> frame) => scheduleMicrotask(() => _incoming.add(jsonEncode(frame)));

  @override
  Future<void> close() => _incoming.close();
}

class FakeRelayApi implements RelayApi {
  final String root;
  final repos = <Repo>[];
  final calls = <String>[];

  FakeRelayApi({this.root = '/home/me/src/proj'});

  @override
  Future<Workspace> ensureProject(String projectId) async {
    calls.add('ensure $projectId');
    return Workspace(root, List.of(repos));
  }

  @override
  Future<List<Repo>> attachRepo(String projectId, String url, {String? branch}) async {
    calls.add('attach $url');
    if (!url.startsWith('https://')) throw const RelayException('Use an https git URL without credentials in it.');
    repos.add(Repo(name: url.split('/').last.replaceAll('.git', ''), url: url, branch: branch ?? 'main'));
    return List.of(repos);
  }

  @override
  Future<List<Repo>> detachRepo(String projectId, String name) async {
    repos.removeWhere((r) => r.name == name);
    return List.of(repos);
  }

  @override
  Future<void> deleteProject(String projectId) async => calls.add('delete $projectId');
}

/// Lets queued microtasks and stream events run.
Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
