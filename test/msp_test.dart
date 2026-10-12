import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muse_code/src/msp.dart';

class LoopTransport implements MspTransport {
  final _in = StreamController<String>();
  final sent = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onSend;

  @override
  Stream<String> get incoming => _in.stream;
  void push(Object frame) => _in.add(jsonEncode(frame));

  @override
  void send(String frame) {
    final j = jsonDecode(frame) as Map<String, dynamic>;
    sent.add(j);
    onSend?.call(j);
  }

  @override
  Future<void> close() => _in.close();
}

void main() {
  test('uuidv7 has version 7 and the variant bits', () {
    final id = uuidv7();
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(uuidv7(), isNot(id));
  });

  test('cursorSeq reads the sequence at the end of a view cursor', () {
    expect(cursorSeq('v:0198f0aa-1111-7000-8000-0000000000aa:14'), 14);
    expect(cursorSeq(null), isNull);
  });

  test('requests, errors, notifications and host requests', () async {
    final t = LoopTransport();
    t.onSend = (f) {
      if (f['method'] == 'model/list') t.push({'jsonrpc': '2.0', 'id': f['id'], 'result': {'models': []}});
      if (f['method'] == 'turn/start') {
        t.push({'jsonrpc': '2.0', 'id': f['id'], 'error': {'code': -32030, 'message': 'busy'}});
      }
    };
    final c = MspClient(t)..onServerRequest = (method, params) => {'seen': method};
    final events = <String>[];
    c.notifications.listen((e) => events.add(e.$1));

    expect(await c.request('model/list', {'sessionId': 's'}), {'models': []});
    await expectLater(c.command('turn/start', {'sessionId': 's'}), throwsA(isA<MspError>().having((e) => e.code, 'code', -32030)));
    expect((t.sent.last['params'] as Map)['commandId'], isA<String>());

    t.push({'jsonrpc': '2.0', 'method': 'turn/started', 'params': {'sessionId': 's'}});
    t.push({'jsonrpc': '2.0', 'id': 1, 'method': 'approval/request', 'params': {}});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['turn/started']);
    expect(t.sent.last, {'jsonrpc': '2.0', 'id': 1, 'result': {'seen': 'approval/request'}});

    final pending = c.request('session/list');
    await t.close();
    await expectLater(pending, throwsA(isA<MspError>()));
    expect(c.isClosed, isTrue);
  });
}
