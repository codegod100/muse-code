import 'dart:io';

import 'host.dart';

Host createHost() => IoHost();

class IoHost implements Host {
  /// Overrides the state file, for tests.
  final String? statePath;

  IoHost({this.statePath});

  @override
  String get stateLocation => _stateFile.path;

  File get _stateFile {
    if (statePath != null) return File(statePath!);
    final env = Platform.environment;
    final String base;
    if (Platform.isWindows) {
      base = env['APPDATA'] ?? '.';
    } else if (Platform.isMacOS) {
      base = '${env['HOME']}/Library/Application Support';
    } else {
      base = env['XDG_CONFIG_HOME'] ?? '${env['HOME']}/.config';
    }
    return File('$base${Platform.pathSeparator}muse_code${Platform.pathSeparator}state.json');
  }

  @override
  Future<String?> loadState() async {
    final f = _stateFile;
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> saveState(String json) async {
    final f = _stateFile;
    await f.parent.create(recursive: true);
    // Write then rename, so a crash mid-save can't leave half a file.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(f.path);
  }
}
