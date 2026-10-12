/// What the app needs from the machine it runs on: saving state, and the
/// file and shell tools workers use. Desktop builds get the real thing;
/// the web build talks to Claude but has no folder to work in.
library;

import '../anthropic.dart';
import 'host_stub.dart' if (dart.library.io) 'host_io.dart' as impl;

class ToolResult {
  final String output;
  final bool isError;
  const ToolResult(this.output, {this.isError = false});
  const ToolResult.error(this.output) : isError = true;
}

abstract class Host {
  /// Whether file and command tools work here.
  bool get hasFiles;

  /// ANTHROPIC_API_KEY from the environment, when set.
  String? get envApiKey;

  /// Where state is saved, for the settings dialog.
  String get stateLocation;

  Future<String?> loadState();
  Future<void> saveState(String json);

  bool directoryExists(String path);

  Future<ToolResult> runTool(
    String name,
    Map<String, dynamic> input, {
    required String root,
    required CancelToken cancel,
  });
}

Host createHost() => impl.createHost();
