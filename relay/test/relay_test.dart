import 'dart:convert';
import 'dart:io';

import 'package:muse_relay/relay.dart';
import 'package:test/test.dart';

const token = 'test-token-0123456789';

void main() {
  late Directory tmp;
  late Relay relay;
  late String base;
  final client = HttpClient();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('relay');
    // A stand-in host that echoes each frame back.
    final bin = File('${tmp.path}/fake-muse');
    await bin.writeAsString('#!/bin/sh\nwhile IFS= read -r l; do printf \'%s\\n\' "echo:\$l"; done\n');
    await Process.run('chmod', ['+x', bin.path]);
    relay = Relay(RelayConfig(token: token, museBin: bin.path, workspaces: '${tmp.path}/ws'));
    await relay.start(port: 0, address: InternetAddress.loopbackIPv4);
    base = 'http://127.0.0.1:${relay.port}';
  });

  tearDown(() async {
    await relay.close();
    await tmp.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> call(String method, String path, {Object? body, bool auth = true}) async {
    final req = await client.openUrl(method, Uri.parse('$base$path'));
    if (auth) req.headers.set('Authorization', 'Bearer $token');
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    return (res.statusCode, jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>);
  }

  test('health needs no token, everything else does', () async {
    expect((await call('GET', '/health', auth: false)).$1, 200);
    expect((await call('POST', '/projects', body: {'id': 'p1'}, auth: false)).$1, 401);
  });

  test('a project is a folder created from an id, with no repos yet', () async {
    final (status, body) = await call('POST', '/projects', body: {'id': 'p1'});
    expect(status, 200);
    expect(body['root'], '${tmp.path}/ws/p1');
    expect(body['repos'], isEmpty);
    expect(File('${tmp.path}/ws/p1/AGENTS.md').existsSync(), isTrue);
    expect((await call('POST', '/projects', body: {'id': '../x'})).$1, 400);
  });

  test('repos must be https URLs without credentials', () async {
    await call('POST', '/projects', body: {'id': 'p1'});
    expect((await call('POST', '/projects/p1/repos', body: {'url': 'file:///etc'})).$1, 400);
    expect((await call('POST', '/projects/p1/repos', body: {'url': 'https://u:p@github.com/a/b'})).$1, 400);
    expect((await call('GET', '/projects/nope/repos')).$1, 404);
  });

  test('the WebSocket is piped line by line to the host', () async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${relay.port}/msp', protocols: ['msp', 'bearer.$token']);
    expect(ws.protocol, 'msp');
    final first = ws.first;
    ws.add('{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    expect(await first, 'echo:{"jsonrpc":"2.0","id":1,"method":"initialize"}');
    await ws.close();
  });

  test('a WebSocket without the token is refused', () async {
    expect(() => WebSocket.connect('ws://127.0.0.1:${relay.port}/msp', protocols: ['msp']),
        throwsA(isA<WebSocketException>()));
  });
}
