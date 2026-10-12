import 'host.dart';

Host createHost() => MemoryHost();

class MemoryHost implements Host {
  String? _state;

  @override
  String get stateLocation => 'this browser tab (not saved)';

  @override
  Future<String?> loadState() async => _state;

  @override
  Future<void> saveState(String json) async => _state = json;
}
