/// Where the app keeps its own state between runs. All work happens on
/// the cloud host; this is only the app's view of projects and threads.
library;

import 'host_stub.dart' if (dart.library.io) 'host_io.dart' as impl;

abstract class Host {
  /// Where state is saved, for the settings dialog.
  String get stateLocation;

  Future<String?> loadState();
  Future<void> saveState(String json);
}

Host createHost() => impl.createHost();
