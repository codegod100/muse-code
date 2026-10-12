/// A small streaming client for the Claude Messages API. Dart has no
/// official Anthropic SDK, so this talks to `POST /v1/messages` directly
/// and rebuilds the assistant message from the server-sent events.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Models offered in settings, most capable first.
const claudeModels = [
  ('claude-opus-5-5', 'Claude Opus 5.5'),
  ('claude-sonnet-5-5', 'Claude Sonnet 5.5'),
  ('claude-haiku-5-5', 'Claude Haiku 5.5'),
];

const effortLevels = ['low', 'medium', 'high', 'xhigh', 'max'];

/// One finished assistant turn: its content blocks exactly as the API sent
/// them (thinking blocks included, so they can be passed back unchanged),
/// and why it stopped.
class AssistantTurn {
  final List<Map<String, dynamic>> content;
  final String? stopReason;
  final int inputTokens;
  final int outputTokens;

  const AssistantTurn({
    required this.content,
    required this.stopReason,
    this.inputTokens = 0,
    this.outputTokens = 0,
  });

  String get text => content
      .where((b) => b['type'] == 'text')
      .map((b) => b['text'] as String? ?? '')
      .join('\n\n')
      .trim();

  List<Map<String, dynamic>> get toolUses =>
      content.where((b) => b['type'] == 'tool_use').toList();
}

class ApiException implements Exception {
  final String message;
  final int? status;
  ApiException(this.message, {this.status});
  @override
  String toString() => status == null ? message : 'HTTP $status: $message';
}

class CancelledException implements Exception {
  @override
  String toString() => 'Stopped';
}

/// Lets a running request or tool be stopped from the UI.
class CancelToken {
  bool _cancelled = false;
  final _callbacks = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final cb in List.of(_callbacks)) {
      cb();
    }
    _callbacks.clear();
  }

  /// Runs [cb] on cancel, straight away if already cancelled. Returns a
  /// function that unregisters it.
  void Function() onCancel(void Function() cb) {
    if (_cancelled) {
      cb();
      return () {};
    }
    _callbacks.add(cb);
    return () => _callbacks.remove(cb);
  }

  void throwIfCancelled() {
    if (_cancelled) throw CancelledException();
  }
}

/// What the agent loop needs from a model backend. Tests swap in a fake.
abstract class LlmClient {
  Future<AssistantTurn> send({
    required String model,
    required String effort,
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required CancelToken cancel,
    void Function(String textDelta)? onText,
  });
}

class AnthropicClient implements LlmClient {
  final String apiKey;
  final String baseUrl;
  final http.Client Function() _newClient;

  AnthropicClient({
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    http.Client Function()? clientFactory,
  }) : _newClient = clientFactory ?? http.Client.new;

  static bool _supportsFallbacks(String model) =>
      model.startsWith('claude-opus-5') ||
      model.startsWith('claude-sonnet-5-5') ||
      model.startsWith('claude-fable');

  Map<String, dynamic> buildBody({
    required String model,
    required String effort,
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) =>
      {
        'model': model,
        'max_tokens': 64000,
        'stream': true,
        'system': system,
        'messages': messages,
        if (tools.isNotEmpty) 'tools': tools,
        'thinking': {'type': 'adaptive'},
        'output_config': {'effort': effort},
        // Caches the growing conversation prefix between turns.
        'cache_control': {'type': 'ephemeral'},
        // Lets a declined request be retried on another model server-side.
        if (_supportsFallbacks(model)) 'fallbacks': 'default',
      };

  @override
  Future<AssistantTurn> send({
    required String model,
    required String effort,
    required String system,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required CancelToken cancel,
    void Function(String textDelta)? onText,
  }) async {
    cancel.throwIfCancelled();
    final client = _newClient();
    final unregister = cancel.onCancel(client.close);
    try {
      final request = http.Request('POST', Uri.parse('$baseUrl/v1/messages'))
        ..headers.addAll({
          'content-type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
          if (_supportsFallbacks(model)) 'anthropic-beta': 'server-side-fallback-2026-07-01',
          if (kIsWeb) 'anthropic-dangerous-direct-browser-access': 'true',
        })
        ..body = jsonEncode(buildBody(
          model: model,
          effort: effort,
          system: system,
          messages: messages,
          tools: tools,
        ));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw ApiException(_errorMessage(body), status: response.statusCode);
      }
      final assembler = TurnAssembler(onText: onText);
      await for (final event in parseSse(response.stream)) {
        assembler.add(event.$1, event.$2);
      }
      return assembler.finish();
    } on http.ClientException {
      if (cancel.isCancelled) throw CancelledException();
      rethrow;
    } catch (_) {
      if (cancel.isCancelled) throw CancelledException();
      rethrow;
    } finally {
      unregister();
      client.close();
    }
  }

  static String _errorMessage(String body) {
    try {
      final json = jsonDecode(body);
      return json['error']?['message'] as String? ?? body;
    } catch (_) {
      return body;
    }
  }
}

/// Splits a server-sent event byte stream into (event, data) pairs.
Stream<(String, Map<String, dynamic>)> parseSse(Stream<List<int>> bytes) async* {
  var event = '';
  final data = StringBuffer();
  await for (final line in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final decoded = jsonDecode(data.toString());
        if (decoded is Map<String, dynamic>) {
          yield (event.isEmpty ? (decoded['type'] as String? ?? '') : event, decoded);
        }
      }
      event = '';
      data.clear();
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (data.isNotEmpty) data.write('\n');
      data.write(line.substring(5).trimLeft());
    }
  }
  if (data.isNotEmpty) {
    final decoded = jsonDecode(data.toString());
    if (decoded is Map<String, dynamic>) yield (event, decoded);
  }
}

/// Rebuilds an assistant message from stream events.
class TurnAssembler {
  final void Function(String)? onText;
  final _blocks = <int, Map<String, dynamic>>{};
  final _json = <int, StringBuffer>{};
  String? _stopReason;
  int _input = 0;
  int _output = 0;

  TurnAssembler({this.onText});

  void add(String event, Map<String, dynamic> data) {
    switch (data['type'] ?? event) {
      case 'message_start':
        final usage = data['message']?['usage'];
        if (usage is Map) {
          _input = (usage['input_tokens'] as int? ?? 0) +
              (usage['cache_read_input_tokens'] as int? ?? 0) +
              (usage['cache_creation_input_tokens'] as int? ?? 0);
        }
      case 'content_block_start':
        final i = data['index'] as int;
        _blocks[i] = Map<String, dynamic>.from(data['content_block'] as Map);
        if (_blocks[i]!['type'] == 'tool_use') _json[i] = StringBuffer();
      case 'content_block_delta':
        final i = data['index'] as int;
        final block = _blocks[i];
        final delta = data['delta'] as Map;
        if (block == null) return;
        switch (delta['type']) {
          case 'text_delta':
            final t = delta['text'] as String;
            block['text'] = (block['text'] as String? ?? '') + t;
            onText?.call(t);
          case 'thinking_delta':
            block['thinking'] = (block['thinking'] as String? ?? '') + (delta['thinking'] as String);
          case 'signature_delta':
            block['signature'] = delta['signature'];
          case 'input_json_delta':
            _json[i]?.write(delta['partial_json'] as String);
        }
      case 'content_block_stop':
        final i = data['index'] as int;
        final buffer = _json.remove(i);
        if (buffer != null) {
          final raw = buffer.toString();
          try {
            _blocks[i]!['input'] = raw.trim().isEmpty ? <String, dynamic>{} : jsonDecode(raw);
          } catch (_) {
            // Kept so the tool call can be answered with an error instead
            // of leaving the history unbalanced.
            _blocks[i]!['input'] = <String, dynamic>{'_invalid_json': raw};
          }
        }
      case 'message_delta':
        _stopReason = data['delta']?['stop_reason'] as String? ?? _stopReason;
        final usage = data['usage'];
        if (usage is Map) _output = usage['output_tokens'] as int? ?? _output;
      case 'error':
        throw ApiException(data['error']?['message'] as String? ?? 'Stream error');
    }
  }

  AssistantTurn finish() {
    final keys = _blocks.keys.toList()..sort();
    return AssistantTurn(
      content: [for (final k in keys) _blocks[k]!],
      stopReason: _stopReason,
      inputTokens: _input,
      outputTokens: _output,
    );
  }
}
