/// A client for the Muse Session Protocol (MSP): JSON-RPC 2.0 frames, one
/// per message, exchanged with a `muse serve` host. Here the host runs in
/// the cloud behind the Muse relay, so the frames travel over a WebSocket.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Moves MSP frames to and from a host.
abstract class MspTransport {
  Stream<String> get incoming;
  void send(String frame);
  Future<void> close();
}

/// The relay's `/msp` WebSocket. The relay token rides in the
/// `bearer.<token>` subprotocol, because browsers can't set an
/// Authorization header on a WebSocket.
class WebSocketTransport implements MspTransport {
  final WebSocketChannel _channel;
  WebSocketTransport._(this._channel);

  static Future<WebSocketTransport> connect(Uri relay, String token) async {
    final uri = relay.replace(
      scheme: relay.scheme == 'https' ? 'wss' : (relay.scheme == 'http' ? 'ws' : relay.scheme),
      path: '${relay.path.endsWith('/') ? relay.path.substring(0, relay.path.length - 1) : relay.path}/msp',
    );
    final channel = WebSocketChannel.connect(uri, protocols: ['msp', 'bearer.$token']);
    await channel.ready;
    return WebSocketTransport._(channel);
  }

  @override
  Stream<String> get incoming => _channel.stream.where((f) => f is String).cast<String>();

  @override
  void send(String frame) => _channel.sink.add(frame);

  @override
  Future<void> close() => _channel.sink.close();
}

class MspError implements Exception {
  final int code;
  final String message;
  final Object? data;
  const MspError(this.code, this.message, [this.data]);

  static const disconnected = -32099;

  @override
  String toString() => message;
}

typedef ServerRequestHandler = FutureOr<Map<String, dynamic>> Function(String method, Map<String, dynamic> params);

/// A UUIDv7: what MSP wants for every `commandId`.
String uuidv7() {
  final r = Random.secure();
  final ms = DateTime.now().millisecondsSinceEpoch;
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  for (var i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  b[6] = 0x70 | (b[6] & 0x0f);
  b[8] = 0x80 | (b[8] & 0x3f);
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// The number at the end of a `v:<session>:<n>` view cursor.
int? cursorSeq(Object? cursor) {
  if (cursor is! String) return null;
  final i = cursor.lastIndexOf(':');
  return i < 0 ? null : int.tryParse(cursor.substring(i + 1));
}

class MspClient {
  final MspTransport _transport;
  int _nextId = 1;
  final Map<Object, Completer<Map<String, dynamic>>> _pending = {};
  final _notifications = StreamController<(String, Map<String, dynamic>)>.broadcast(sync: true);
  final _closed = Completer<void>();
  late final StreamSubscription<String> _sub;

  /// Answers requests the host sends us, such as `approval/request`.
  ServerRequestHandler? onServerRequest;

  /// The `initialize` result: who answered, and its schema fingerprint.
  Map<String, dynamic>? serverInfo;

  MspClient(this._transport) {
    _sub = _transport.incoming.listen(_receive, onDone: _onDone, onError: (_) => _onDone());
  }

  /// Host-pushed events: `(method, params)`.
  Stream<(String, Map<String, dynamic>)> get notifications => _notifications.stream;

  /// Completes when the connection drops.
  Future<void> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;

  Future<Map<String, dynamic>> initialize({String name = 'muse_code', String version = '0.1.0'}) async {
    serverInfo = await request('initialize', {
      'clientInfo': {'name': name, 'version': version},
    });
    notify('initialized');
    return serverInfo!;
  }

  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic>? params]) {
    if (isClosed) return Future.error(const MspError(MspError.disconnected, 'Not connected to the Muse host.'));
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, if (params != null) 'params': params});
    return c.future;
  }

  /// A state-changing request: carries a fresh `commandId` unless [params]
  /// already has one, so a retry joins the original command.
  Future<Map<String, dynamic>> command(String method, Map<String, dynamic> params) =>
      request(method, {'commandId': uuidv7(), ...params});

  void notify(String method, [Map<String, dynamic>? params]) {
    if (isClosed) return;
    _send({'jsonrpc': '2.0', 'method': method, if (params != null) 'params': params});
  }

  Future<void> close() async {
    await _transport.close();
    _onDone();
  }

  void _send(Map<String, dynamic> frame) => _transport.send(jsonEncode(frame));

  void _receive(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final method = decoded['method'];
    final id = decoded['id'];
    final params = (decoded['params'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    if (method is String && id != null) {
      unawaited(_answer(id, method, params));
    } else if (method is String) {
      _notifications.add((method, params));
    } else if (id != null) {
      final c = _pending.remove(id);
      if (c == null) return;
      final error = decoded['error'];
      if (error is Map) {
        c.completeError(MspError(error['code'] as int? ?? -32603, '${error['message'] ?? 'Request failed.'}', error['data']));
      } else {
        c.complete((decoded['result'] as Map?)?.cast<String, dynamic>() ?? {});
      }
    }
  }

  Future<void> _answer(Object id, String method, Map<String, dynamic> params) async {
    final handler = onServerRequest;
    try {
      if (handler == null) throw MspError(-32601, 'Unhandled method $method');
      final result = await handler(method, params);
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});
    } on MspError catch (e) {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': e.code, 'message': e.message},
      });
    } catch (e) {
      _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32603, 'message': '$e'},
      });
    }
  }

  void _onDone() {
    if (_closed.isCompleted) return;
    _closed.complete();
    unawaited(_sub.cancel());
    for (final c in _pending.values) {
      c.completeError(const MspError(MspError.disconnected, 'The connection to the Muse host closed.'));
    }
    _pending.clear();
    unawaited(_notifications.close());
  }
}
