import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'src/engine.dart';
import 'src/host/host.dart';
import 'src/ui/shell.dart';

void main() {
  final controller = MuseController(host: createHost())..load();
  runApp(MuseApp(controller: controller));
}

class MuseApp extends StatefulWidget {
  final MuseController controller;
  const MuseApp({super.key, required this.controller});

  @override
  State<MuseApp> createState() => _MuseAppState();
}

class _MuseAppState extends State<MuseApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      widget.controller.saveNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        Widget app(KitColors colors) => MaterialApp(
              title: 'Muse Code',
              debugShowCheckedModeBanner: false,
              theme: KitTheme.material(colors),
              builder: (context, child) => KitTheme(
                colors: colors,
                child: Material(color: colors.background, child: child),
              ),
              home: Shell(controller: controller),
            );
        return switch (controller.settings.theme) {
          'light' => app(KitColors.light),
          'dark' => app(KitColors.dark),
          _ => KitSystemTheme(builder: (context, colors) => app(colors)),
        };
      },
    );
  }
}
