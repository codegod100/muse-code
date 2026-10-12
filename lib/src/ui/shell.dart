/// The window: projects on the left, the selected project's threads next
/// to them, and the selected thread's conversation filling the rest.
library;

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons, InputBorder, InputDecoration, SelectionArea, TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../engine.dart';
import '../model.dart';
import 'dialogs.dart';
import 'entries.dart';
import 'markdown.dart';

class Shell extends StatelessWidget {
  final MuseController controller;
  const Shell({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.loaded) return const Center(child: KitSpinner(size: 20));
        final project = controller.project;
        return LayoutBuilder(builder: (context, size) {
          final wide = size.maxWidth >= 880;
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (wide) ...[
              SizedBox(width: 210, child: ProjectsPane(controller: controller)),
              const KitVerticalDivider(),
            ],
            if (project != null) ...[
              SizedBox(width: 250, child: ThreadsPane(controller: controller, project: project, showProjectPicker: !wide)),
              const KitVerticalDivider(),
              Expanded(
                child: ChatPane(
                  key: ValueKey(controller.thread!.id),
                  controller: controller,
                  project: project,
                  thread: controller.thread!,
                ),
              ),
            ] else
              Expanded(child: _Welcome(controller: controller)),
          ]);
        });
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const _SectionLabel(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 6, 4),
        child: Row(children: [
          Expanded(
            child: Text(text.toUpperCase(),
                style: KitText.dim(context, small: true).copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.6, fontSize: 11)),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

class ProjectsPane extends StatelessWidget {
  final MuseController controller;
  const ProjectsPane({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final selected = controller.project;
    return Container(
      color: c.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(6)),
              child: Icon(Icons.auto_awesome, size: 14, color: c.onAccent),
            ),
            const SizedBox(width: 10),
            Text('Muse Code', style: KitText.heading(context).copyWith(fontSize: 15)),
          ]),
        ),
        _SectionLabel('Projects',
            trailing: KitIconButton.compact(Icons.add,
                tooltip: 'New project', onPressed: () => showProjectDialog(context, controller))),
        Expanded(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 6), children: [
            for (final p in controller.projects)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(kitRadius),
                  child: KitListRow(
                    height: 32,
                    selected: p.id == selected?.id,
                    active: false,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onTap: () => controller.selectProject(p.id),
                    child: Row(children: [
                      const Icon(Icons.folder_outlined, size: 16),
                      const SizedBox(width: 8),
                      Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (p.threads.any((t) => t.isBusy)) const StatusDot(ThreadStatus.running),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        const KitDivider(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            KitButton.ghost('Settings', icon: Icons.settings_outlined, onPressed: () => showSettingsDialog(context, controller)),
          ]),
        ),
      ]),
    );
  }
}

class ThreadsPane extends StatelessWidget {
  final MuseController controller;
  final Project project;
  final bool showProjectPicker;

  const ThreadsPane({super.key, required this.controller, required this.project, this.showProjectPicker = false});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final current = controller.thread;
    final workers = project.workers.toList().reversed.toList();
    final running = workers.where((w) => w.isBusy).length;

    Widget row(ChatThread t, {required IconData icon, String? subtitle}) => Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(kitRadius),
            child: KitListRow(
              height: subtitle == null ? 34 : 46,
              selected: t.id == current?.id,
              active: false,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              onTap: () => controller.selectThread(t.id),
              child: Row(children: [
                Icon(icon, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (subtitle != null)
                      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.dim(context, small: true)),
                  ]),
                ),
                const SizedBox(width: 6),
                StatusDot(t.status),
              ]),
            ),
          ),
        );

    return Container(
      color: c.background,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 52,
          padding: const EdgeInsets.only(left: 12, right: 6),
          child: Row(children: [
            Expanded(
              child: showProjectPicker
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: KitSelect<String>(
                        value: project.id,
                        options: [for (final p in controller.projects) (p.id, p.name)],
                        onChanged: controller.selectProject,
                      ),
                    )
                  : Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.heading(context)),
                      Text(project.root.isEmpty ? 'No folder' : project.root,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.dim(context, small: true)),
                    ]),
            ),
            KitMenu(
              items: () => [
                if (showProjectPicker) KitMenuItem('New project', onSelected: () => showProjectDialog(context, controller)),
                KitMenuItem('Project settings', onSelected: () => showProjectDialog(context, controller, project: project)),
                if (showProjectPicker) KitMenuItem('Settings', onSelected: () => showSettingsDialog(context, controller)),
                const KitMenuDivider(),
                KitMenuItem('Delete project', danger: true, onSelected: () async {
                  if (await confirm(context,
                      title: 'Delete ${project.name}?',
                      body: 'Its threads are removed from Muse Code. Files in the folder are not touched.',
                      action: 'Delete')) {
                    controller.deleteProject(project);
                  }
                }),
              ],
              builder: (context, toggle, open) =>
                  KitIconButton(Icons.more_horiz, tooltip: 'Project', onPressed: toggle),
            ),
          ]),
        ),
        const KitDivider(),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(6, 6, 6, 12), children: [
            row(project.main, icon: Icons.hub_outlined, subtitle: 'Orchestrator'),
            _SectionLabel(
              running > 0 ? 'Workers · $running working' : 'Workers',
            ),
            if (workers.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text('Workers appear here when the orchestrator hands out tasks.',
                    style: KitText.dim(context, small: true)),
              ),
            for (final w in workers) row(w, icon: Icons.smart_toy_outlined, subtitle: statusLabel(w.status)),
          ]),
        ),
      ]),
    );
  }
}

class _Welcome extends StatelessWidget {
  final MuseController controller;
  const _Welcome({required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.hub_outlined, size: 36, color: c.accent),
          const SizedBox(height: 16),
          Text('Start a project', style: KitText.heading(context).copyWith(fontSize: 20)),
          const SizedBox(height: 8),
          Text(
            'Point a project at a folder and tell its orchestrator what you want. It splits the work into '
            'worker threads that read, edit and test the code, and reports back as each one finishes.',
            style: KitText.dim(context).copyWith(height: 1.5),
          ),
          const SizedBox(height: 20),
          Row(children: [
            KitButton.primary('New project', icon: Icons.add, onPressed: () => showProjectDialog(context, controller)),
            const SizedBox(width: 8),
            KitButton('Settings', icon: Icons.settings_outlined, onPressed: () => showSettingsDialog(context, controller)),
          ]),
        ]),
      ),
    );
  }
}

class ChatPane extends StatefulWidget {
  final MuseController controller;
  final Project project;
  final ChatThread thread;

  const ChatPane({super.key, required this.controller, required this.project, required this.thread});

  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = (node, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _send();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty || widget.controller.apiKey.isEmpty) return;
    widget.controller.sendUserMessage(widget.project, widget.thread, text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final t = widget.thread;
    final controller = widget.controller;
    final busy = t.isBusy;
    final noKey = controller.apiKey.isEmpty;

    // Newest first, so the reversed list stays pinned to the bottom.
    final items = <Widget>[
      if (busy) _WorkingLine(thread: t),
      for (final e in t.entries.reversed)
        EntryView(controller: controller, project: widget.project, thread: t, entry: e),
    ];

    return Container(
      color: c.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Header(controller: controller, project: widget.project, thread: t),
        const KitDivider(),
        Expanded(
          child: t.entries.isEmpty && !busy
              ? _EmptyThread(thread: t, onPick: (s) {
                  _input.text = s;
                  _focus.requestFocus();
                })
              : SelectionArea(
                  child: ListView.separated(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, i) => Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 820),
                        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: items[i]),
                      ),
                    ),
                  ),
                ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (noKey)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Icon(Icons.key_outlined, size: 15, color: c.textDim),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('Add your Anthropic API key to start.', style: KitText.dim(context, small: true)),
                      ),
                      KitButton.ghost('Open settings', onPressed: () => showSettingsDialog(context, controller)),
                    ]),
                  ),
                _Composer(
                  controller: _input,
                  focus: _focus,
                  hint: t.isMain ? 'Tell the orchestrator what to do…' : 'Message this worker directly…',
                  busy: busy,
                  canSend: !noKey,
                  onSend: _send,
                  onStop: () => controller.stop(t),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  final MuseController controller;
  final Project project;
  final ChatThread thread;

  const _Header({required this.controller, required this.project, required this.thread});

  @override
  Widget build(BuildContext context) {
    final t = thread;
    final model = t.isMain ? controller.settings.model : controller.settings.workerModel;
    final tokens = t.inputTokens + t.outputTokens;
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 20, right: 10),
      child: Row(children: [
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.isMain ? 'Main' : t.title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.heading(context).copyWith(fontSize: 15)),
            Text(
              [
                t.isMain ? 'Orchestrator' : 'Worker',
                statusLabel(t.status),
                model,
                if (tokens > 0) '${_compact(tokens)} tokens',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: KitText.dim(context, small: true),
            ),
          ]),
        ),
        if (!t.isMain) ...[
          KitButton.ghost('Back to Main', icon: Icons.hub_outlined, onPressed: () => controller.selectThread(project.main.id)),
          const SizedBox(width: 4),
          KitIconButton(Icons.delete_outline, tooltip: 'Remove worker', onPressed: () async {
            if (await confirm(context,
                title: 'Remove ${t.title}?',
                body: 'The thread and its history are removed. Changes it made to files stay.',
                action: 'Remove')) {
              controller.deleteWorker(project, t);
            }
          }),
        ],
      ]),
    );
  }

  static String _compact(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(1)}M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(1)}k'
          : '$n';
}

class _WorkingLine extends StatelessWidget {
  final ChatThread thread;
  const _WorkingLine({required this.thread});

  @override
  Widget build(BuildContext context) {
    final live = thread.liveText.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (live.isNotEmpty) ...[Markdown(live), const SizedBox(height: 10)],
      Row(children: [
        const KitSpinner(size: 12),
        const SizedBox(width: 8),
        Text(thread.status == ThreadStatus.waiting ? 'Waiting for your approval' : 'Working…',
            style: KitText.dim(context, small: true)),
      ]),
    ]);
  }
}

class _EmptyThread extends StatelessWidget {
  final ChatThread thread;
  final ValueChanged<String> onPick;
  const _EmptyThread({required this.thread, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    const ideas = [
      'Give me a tour of this codebase',
      'Find and fix the failing tests',
      'Add a dark mode toggle and write tests for it',
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(thread.isMain ? Icons.hub_outlined : Icons.smart_toy_outlined, size: 30, color: c.accent),
            const SizedBox(height: 12),
            Text(thread.isMain ? 'What should we work on?' : 'This worker has no messages yet',
                style: KitText.heading(context).copyWith(fontSize: 17)),
            const SizedBox(height: 6),
            Text(
              thread.isMain
                  ? 'The orchestrator splits your request into tasks and starts a worker thread for each. '
                      'Workers show up on the left; their reports land back here.'
                  : 'Anything you send here goes straight to this worker.',
              style: KitText.dim(context).copyWith(height: 1.5),
            ),
            if (thread.isMain) ...[
              const SizedBox(height: 16),
              for (final idea in ideas)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: KitButton(idea, icon: Icons.north_east, onPressed: () => onPick(idea)),
                ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final bool busy;
  final bool canSend;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _Composer({
    required this.controller,
    required this.focus,
    required this.hint,
    required this.busy,
    required this.canSend,
    required this.onSend,
    required this.onStop,
  });

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  void _changed() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_changed);
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_changed);
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final focused = widget.focus.hasFocus;
    final style = KitText.body(context).copyWith(height: 1.5);
    final empty = widget.controller.text.trim().isEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: focused ? c.focus : c.border, width: focused ? 2 : 1),
        boxShadow: [BoxShadow(color: c.shadow, blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: widget.controller,
          focusNode: widget.focus,
          minLines: 1,
          maxLines: 10,
          style: style,
          cursorColor: c.accent,
          cursorWidth: 1.5,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            hintText: widget.hint,
            hintStyle: style.copyWith(color: c.textDim),
            hintFadeDuration: Duration.zero,
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(
              widget.busy ? 'Messages you send now are read when the current step finishes.' : 'Enter to send · Shift+Enter for a new line',
              style: KitText.dim(context, small: true).copyWith(fontSize: 11),
            ),
          ),
          if (widget.busy) ...[
            KitButton('Stop', icon: Icons.stop_circle_outlined, onPressed: widget.onStop),
            const SizedBox(width: 6),
          ],
          KitButton.primary('Send', icon: Icons.arrow_upward, onPressed: empty || !widget.canSend ? null : widget.onSend),
        ]),
      ]),
    );
  }
}
