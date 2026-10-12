import '../anthropic.dart';
import 'host.dart';

Host createHost() => _MemoryHost();

class _MemoryHost implements Host {
  String? _state;

  @override
  bool get hasFiles => false;

  @override
  String? get envApiKey => null;

  @override
  String get stateLocation => 'this browser tab (not saved)';

  @override
  Future<String?> loadState() async => _state;

  @override
  Future<void> saveState(String json) async => _state = json;

  @override
  bool directoryExists(String path) => false;

  @override
  Future<ToolResult> runTool(String name, Map<String, dynamic> input,
          {required String root, required CancelToken cancel}) async =>
      const ToolResult.error('File and command tools need the desktop app.');
}
