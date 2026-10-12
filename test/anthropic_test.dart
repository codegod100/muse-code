import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:muse_code/src/anthropic.dart';

String sse(List<Map<String, dynamic>> events) =>
    events.map((e) => 'event: ${e['type']}\ndata: ${jsonEncode(e)}\n\n').join();

void main() {
  test('rebuilds thinking, text and tool calls from the stream', () async {
    late http.Request sent;
    final body = sse([
      {
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 10, 'cache_read_input_tokens': 5}
        }
      },
      {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'thinking', 'thinking': ''}},
      {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'signature_delta', 'signature': 'abc'}},
      {'type': 'content_block_stop', 'index': 0},
      {'type': 'content_block_start', 'index': 1, 'content_block': {'type': 'text', 'text': ''}},
      {'type': 'ping'},
      {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'Hello '}},
      {'type': 'content_block_delta', 'index': 1, 'delta': {'type': 'text_delta', 'text': 'there'}},
      {'type': 'content_block_stop', 'index': 1},
      {
        'type': 'content_block_start',
        'index': 2,
        'content_block': {'type': 'tool_use', 'id': 'tu_9', 'name': 'read_file', 'input': {}}
      },
      {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': '{"pa'}},
      {'type': 'content_block_delta', 'index': 2, 'delta': {'type': 'input_json_delta', 'partial_json': 'th": "a.txt"}'}},
      {'type': 'content_block_stop', 'index': 2},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'tool_use'},
        'usage': {'output_tokens': 42}
      },
      {'type': 'message_stop'},
    ]);
    final client = AnthropicClient(
      apiKey: 'sk-ant-test',
      clientFactory: () => MockClient.streaming((request, _) async {
        sent = request as http.Request;
        return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
      }),
    );
    final deltas = <String>[];
    final turn = await client.send(
      model: 'claude-opus-5-5',
      effort: 'high',
      system: 'sys',
      messages: [
        {'role': 'user', 'content': 'hi'}
      ],
      tools: [
        {'name': 'read_file', 'input_schema': {'type': 'object'}}
      ],
      cancel: CancelToken(),
      onText: deltas.add,
    );

    expect(sent.headers['x-api-key'], 'sk-ant-test');
    expect(sent.headers['anthropic-version'], '2023-06-01');
    final req = jsonDecode(sent.body) as Map;
    expect(req['model'], 'claude-opus-5-5');
    expect(req['stream'], true);
    expect(req['thinking'], {'type': 'adaptive'});
    expect(req['output_config'], {'effort': 'high'});

    expect(deltas, ['Hello ', 'there']);
    expect(turn.stopReason, 'tool_use');
    expect(turn.text, 'Hello there');
    expect(turn.content[0], {'type': 'thinking', 'thinking': '', 'signature': 'abc'});
    expect(turn.toolUses.single['input'], {'path': 'a.txt'});
    expect(turn.inputTokens, 15);
    expect(turn.outputTokens, 42);
  });

  test('reports API errors with their message', () async {
    final client = AnthropicClient(
      apiKey: 'bad',
      clientFactory: () => MockClient((_) async => http.Response(
          jsonEncode({
            'type': 'error',
            'error': {'type': 'authentication_error', 'message': 'invalid x-api-key'}
          }),
          401)),
    );
    expect(
      () => client.send(
          model: 'claude-opus-5-5',
          effort: 'high',
          system: '',
          messages: const [],
          tools: const [],
          cancel: CancelToken()),
      throwsA(isA<ApiException>()
          .having((e) => e.status, 'status', 401)
          .having((e) => e.message, 'message', 'invalid x-api-key')),
    );
  });
}
