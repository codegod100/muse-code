import 'dart:io';

import 'package:muse_relay/relay.dart';

Future<void> main() async {
  final env = Platform.environment;
  final RelayConfig config;
  try {
    config = RelayConfig.fromEnvironment(env);
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(2);
  }
  if (!config.museEnv.containsKey('META_API_KEY')) {
    stderr.writeln('Warning: neither META_API_KEY nor MUSE_API_KEY is set, so Muse has no model access.');
  }
  final relay = Relay(config);
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  await relay.start(port: port);
  stdout.writeln('Muse relay listening on :$port, workspaces in ${config.workspaces}');
  ProcessSignal.sigterm.watch().listen((_) async {
    await relay.close();
    exit(0);
  });
}
