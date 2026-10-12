import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../anthropic.dart';
import '../engine.dart';
import '../model.dart';

class _Field extends StatelessWidget {
  final String label;
  final String? help;
  final Widget child;
  const _Field({required this.label, required this.child, this.help});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: KitText.body(context).copyWith(fontWeight: FontWeight.w500, fontSize: 13)),
          const SizedBox(height: 6),
          child,
          if (help != null) ...[
            const SizedBox(height: 4),
            Text(help!, style: KitText.dim(context, small: true)),
          ],
        ]),
      );
}

/// Creates a project, or edits one when [project] is given.
Future<void> showProjectDialog(BuildContext context, MuseController controller, {Project? project}) {
  return showKitDialog(context, (_) => _ProjectDialog(controller: controller, project: project));
}

class _ProjectDialog extends StatefulWidget {
  final MuseController controller;
  final Project? project;
  const _ProjectDialog({required this.controller, this.project});

  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
  late final _name = TextEditingController(text: widget.project?.name ?? '');
  late final _root = TextEditingController(text: widget.project?.root ?? '');
  late bool _auto = widget.project?.autoApprove ?? false;

  @override
  void dispose() {
    _name.dispose();
    _root.dispose();
    super.dispose();
  }

  void _save() {
    final c = widget.controller;
    if (widget.project == null) {
      final p = c.createProject(_name.text, _root.text);
      c.updateProject(p, autoApprove: _auto);
    } else {
      c.updateProject(widget.project!, name: _name.text, root: _root.text, autoApprove: _auto);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.controller.host;
    final root = _root.text.trim();
    final missing = host.hasFiles && root.isNotEmpty && !host.directoryExists(root);
    return KitDialog(
      title: widget.project == null ? 'New project' : 'Project settings',
      content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Field(
          label: 'Name',
          child: KitTextField(controller: _name, hint: 'My app', autofocus: true, onSubmitted: (_) => _save()),
        ),
        _Field(
          label: 'Folder',
          help: !host.hasFiles
              ? 'Workers need the desktop app to work with files; here they can only reply.'
              : missing
                  ? 'No folder at that path yet.'
                  : 'Workers read, edit and run commands here. Leave empty for a chat-only project.',
          child: KitTextField(
            controller: _root,
            hint: '/home/you/code/my-app',
            error: missing,
            enabled: host.hasFiles,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'monospace', package: null),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        KitCheckbox(
          value: _auto,
          onChanged: (v) => setState(() => _auto = v),
          label: 'Let workers edit files and run commands without asking',
        ),
      ]),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        KitButton.primary(widget.project == null ? 'Create' : 'Save', onPressed: _save),
      ],
    );
  }
}

Future<void> showSettingsDialog(BuildContext context, MuseController controller) {
  return showKitDialog(context, (_) => _SettingsDialog(controller: controller));
}

class _SettingsDialog extends StatefulWidget {
  final MuseController controller;
  const _SettingsDialog({required this.controller});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final Settings _s = Settings.fromJson(widget.controller.settings.toJson());
  late final _key = TextEditingController(text: _s.apiKey);
  bool _show = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  void _save() {
    widget.controller.updateSettings((s) {
      s.apiKey = _key.text.trim();
      s.model = _s.model;
      s.workerModel = _s.workerModel;
      s.effort = _s.effort;
      s.theme = _s.theme;
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final env = widget.controller.host.envApiKey != null;
    final models = [for (final (id, label) in claudeModels) (id, label)];
    return KitDialog(
      title: 'Settings',
      width: 460,
      content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Field(
          label: 'Anthropic API key',
          help: 'From console.anthropic.com. It starts with sk-ant- and is sent only to api.anthropic.com, '
              'as the x-api-key header.${env ? ' Leave empty to use ANTHROPIC_API_KEY from your environment.' : ''}',
          child: KitTextField(
            controller: _key,
            hint: env ? 'Using ANTHROPIC_API_KEY' : 'sk-ant-…',
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            trailing: KitIconButton.compact(
              _show ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              tooltip: _show ? 'Hide' : 'Show',
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
        ),
        _Field(
          label: 'Orchestrator model',
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitSelect<String>(
                value: _s.model, options: models, onChanged: (v) => setState(() => _s.model = v)),
          ),
        ),
        _Field(
          label: 'Worker model',
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitSelect<String>(
                value: _s.workerModel, options: models, onChanged: (v) => setState(() => _s.workerModel = v)),
          ),
        ),
        _Field(
          label: 'Effort',
          help: 'Higher effort thinks longer and uses more tokens.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitSegmented<String>(
              segments: [for (final e in effortLevels) (e, e)],
              selected: _s.effort,
              onChanged: (v) => setState(() => _s.effort = v),
            ),
          ),
        ),
        _Field(
          label: 'Appearance',
          help: 'Saved in ${widget.controller.host.stateLocation}',
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitSegmented<String>(
              segments: const [('system', 'System'), ('light', 'Light'), ('dark', 'Dark')],
              selected: _s.theme,
              onChanged: (v) => setState(() => _s.theme = v),
            ),
          ),
        ),
      ]),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        KitButton.primary('Save', onPressed: _save),
      ],
    );
  }
}

Future<bool> confirm(BuildContext context, {required String title, required String body, required String action}) async {
  final ok = await showKitDialog<bool>(
    context,
    (context) => KitDialog(
      title: title,
      content: Text(body),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.of(context).pop(false)),
        KitButton.danger(action, onPressed: () => Navigator.of(context).pop(true)),
      ],
    ),
  );
  return ok ?? false;
}
