import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

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

/// Creates a project from a name, or renames one when [project] is given.
/// Repositories are attached afterwards, from the project's menu.
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

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final c = widget.controller;
    if (widget.project == null) {
      c.createProject(_name.text);
    } else {
      c.renameProject(widget.project!, _name.text);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return KitDialog(
      title: widget.project == null ? 'New project' : 'Rename project',
      content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Field(
          label: 'Name',
          help: widget.project == null
              ? 'The project gets its own workspace in the cloud. Attach git repositories to it once it exists.'
              : null,
          child: KitTextField(controller: _name, hint: 'My app', autofocus: true, onSubmitted: (_) => _save()),
        ),
      ]),
      actions: [
        KitButton('Cancel', onPressed: () => Navigator.of(context).pop()),
        KitButton.primary(widget.project == null ? 'Create' : 'Save', onPressed: _save),
      ],
    );
  }
}

/// Lists the git repositories attached to a project and attaches more.
Future<void> showReposDialog(BuildContext context, MuseController controller, Project project) {
  return showKitDialog(context, (_) => _ReposDialog(controller: controller, project: project));
}

class _ReposDialog extends StatefulWidget {
  final MuseController controller;
  final Project project;
  const _ReposDialog({required this.controller, required this.project});

  @override
  State<_ReposDialog> createState() => _ReposDialogState();
}

class _ReposDialogState extends State<_ReposDialog> {
  final _url = TextEditingController();
  final _branch = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _branch.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      _url.clear();
      _branch.clear();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final p = widget.project;
    final ready = widget.controller.settings.configured;
    return KitDialog(
      title: 'Repositories',
      width: 520,
      content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (p.repos.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text('No repositories yet. Each one is cloned into this project\'s cloud workspace, '
                'where Muse can read, change and test it.', style: KitText.dim(context)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: KitPanel(
              child: Column(children: [
                for (final (i, r) in p.repos.indexed) ...[
                  if (i > 0) const KitDivider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(children: [
                      Icon(Icons.source_outlined, size: 16, color: c.textDim),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(r.name, style: KitText.body(context).copyWith(fontWeight: FontWeight.w500)),
                          Text([r.url, if (r.branch.isNotEmpty) r.branch].join(' · '),
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.dim(context, small: true)),
                        ]),
                      ),
                      KitIconButton(Icons.link_off,
                          tooltip: 'Detach and delete the clone',
                          onPressed: _busy ? null : () => _run(() => widget.controller.detachRepo(p, r))),
                    ]),
                  ),
                ],
              ]),
            ),
          ),
        _Field(
          label: 'Git URL',
          help: ready
              ? 'An https URL. Private GitHub repos need GITHUB_TOKEN set on the relay.'
              : 'Set up the relay in Settings first.',
          child: KitTextField(
            controller: _url,
            hint: 'https://github.com/owner/repo',
            autofocus: true,
            enabled: ready && !_busy,
            autocorrect: false,
            enableSuggestions: false,
            error: _error != null,
            onSubmitted: (_) => _attach(),
          ),
        ),
        _Field(
          label: 'Branch',
          child: KitTextField(controller: _branch, hint: 'Default branch', enabled: ready && !_busy, onSubmitted: (_) => _attach()),
        ),
        if (_error != null) Text(_error!, style: KitText.small(context, color: c.danger)),
      ]),
      actions: [
        KitButton('Close', onPressed: () => Navigator.of(context).pop()),
        KitButton.primary(_busy ? 'Working…' : 'Attach', icon: Icons.add, onPressed: !ready || _busy ? null : _attach),
      ],
    );
  }

  void _attach() {
    if (_url.text.trim().isEmpty || _busy) return;
    _run(() => widget.controller.attachRepo(widget.project, _url.text, branch: _branch.text.trim()));
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
  late final _url = TextEditingController(text: _s.relayUrl);
  late final _token = TextEditingController(text: _s.relayToken);
  bool _show = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    widget.controller.updateSettings((s) {
      s.relayUrl = _url.text.trim();
      s.relayToken = _token.text.trim();
      s.theme = _s.theme;
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return KitDialog(
      title: 'Settings',
      width: 460,
      content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Field(
          label: 'Relay URL',
          help: 'The Muse relay running in the cloud. It hosts Muse, your project workspaces and their repos.',
          child: KitTextField(
            controller: _url,
            hint: 'https://muse-relay.example.com',
            autocorrect: false,
            enableSuggestions: false,
          ),
        ),
        _Field(
          label: 'Relay token',
          help: 'The relay\'s MUSE_RELAY_TOKEN. It is sent only to the relay, as Authorization: Bearer <token>. '
              'Your Meta API key stays on the relay and never comes to this app.',
          child: KitTextField(
            controller: _token,
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
          label: 'Appearance',
          help: 'Saved in ${controller.host.stateLocation}',
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitSegmented<String>(
              segments: const [('system', 'System'), ('light', 'Light'), ('dark', 'Dark')],
              selected: _s.theme,
              onChanged: (v) => setState(() => _s.theme = v),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Text(
            switch (controller.connection) {
              Connection.online => 'Connected to ${controller.hostLabel ?? 'Muse'}.',
              Connection.connecting => 'Connecting…',
              Connection.offline => controller.connectionError ?? 'Not connected.',
            },
            style: KitText.dim(context, small: true),
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
