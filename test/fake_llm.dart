import 'dart:async';

import 'package:muse_code/src/anthropic.dart';

typedef Script = AssistantTurn Function(String system, List<Map<String, dynamic>> messages);

/// Answers from a script instead of the API, recording each request.
class FakeLlm implements LlmClient {
  final Script script;
  final requests = <({String model, String system, List<Map<String, dynamic>> messages, List<String> tools})>[];

  /// When set, each call waits for this before answering.
  Completer<void>? gate;

  FakeLlm(this.script);

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
    requests.add((
      model: model,
      system: system,
      messages: [for (final m in messages) Map.of(m)],
      tools: [for (final t in tools) t['name'] as String],
    ));
    await Future<void>.delayed(Duration.zero);
    if (gate != null) await gate!.future;
    cancel.throwIfCancelled();
    final turn = script(system, messages);
    final text = turn.text;
    if (text.isNotEmpty) onText?.call(text);
    return turn;
  }
}

AssistantTurn text(String t) => AssistantTurn(content: [
      {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
      {'type': 'text', 'text': t},
    ], stopReason: 'end_turn');

AssistantTurn toolCall(String name, Map<String, dynamic> input, {String id = 'tu_1', String? say}) =>
    AssistantTurn(content: [
      if (say != null) {'type': 'text', 'text': say},
      {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
    ], stopReason: 'tool_use');

/// The text of the newest user message, tool results included.
String lastUserText(List<Map<String, dynamic>> messages) {
  final last = messages.last;
  final content = last['content'];
  if (content is String) return content;
  return [
    for (final b in content as List)
      if (b['type'] == 'text') b['text'] else if (b['type'] == 'tool_result') 'RESULT:${b['content']}'
  ].join('\n');
}
