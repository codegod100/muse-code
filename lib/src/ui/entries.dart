/// The pieces of a transcript: messages, tool calls, approvals and worker
/// reports.
library;

import 'dart:convert';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import '../engine.dart';
import '../model.dart';
import 'markdown.dart';

Color statusColor(KitColors c, ThreadStatus s) => switch (s) {
      ThreadStatus.running => c.accent,
      ThreadStatus.waiting => const Color(0xFFE5A50A),
      ThreadStatus.done => c.success,
      ThreadStatus.error => c.danger,
      ThreadStatus.stopped => c.borderStrong,
      ThreadStatus.idle => c.borderStrong,
    };

String statusLabel(ThreadStatus s) => switch (s) {
      ThreadStatus.running => 'Working',
      ThreadStatus.waiting => 'Needs approval',
      ThreadStatus.done => 'Done',
      ThreadStatus.error => 'Failed',
      ThreadStatus.stopped => 'Stopped',
      ThreadStatus.idle => 'Idle',
    };

/// A dot for a thread's status, or a spinner while it works.
class StatusDot extends StatelessWidget {
  final ThreadStatus status;
  const StatusDot(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    if (status == ThreadStatus.running) return const KitSpinner(size: 12);
    return Container(
      width: 8,
      height: 8,
      margin: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: statusColor(c, status), shape: BoxShape.circle),
    );
  }
}

class EntryView extends StatelessWidget {
  final MuseController controller;
  final Project project;
  final ChatThread thread;
  final Entry entry;

  const EntryView({
    super.key,
    required this.controller,
    required this.project,
    required this.thread,
    required this.entry,
  });

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    switch (entry.kind) {
      case EntryKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: c.hover,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(entry.text, style: KitText.body(context).copyWith(height: 1.5)),
            ),
          ),
        );
      case EntryKind.assigned:
        return _Card(
          icon: Icons.assignment_outlined,
          title: thread.isMain ? 'Message' : 'Task from the orchestrator',
          child: Markdown(entry.text),
        );
      case EntryKind.assistant:
        return Markdown(entry.text);
      case EntryKind.tool:
        return ToolRow(controller: controller, project: project, entry: entry);
      case EntryKind.report:
        final w = project.thread(entry.workerId ?? '');
        return _Card(
          icon: Icons.inbox_outlined,
          title: 'Report from ${w?.title ?? 'a removed worker'}',
          leading: w == null ? null : StatusDot(w.status),
          action: w == null
              ? null
              : KitButton.ghost('Open thread', onPressed: () => controller.selectThread(w.id)),
          child: Markdown(entry.text),
        );
      case EntryKind.notice:
        return Row(children: [
          Icon(Icons.info_outline, size: 14, color: c.textDim),
          const SizedBox(width: 6),
          Expanded(child: Text(entry.text, style: KitText.dim(context, small: true))),
        ]);
    }
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget? leading;
  final Widget? action;
  final Widget child;

  const _Card({required this.icon, required this.title, required this.child, this.leading, this.action});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return KitPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          height: 36,
          padding: const EdgeInsets.only(left: 12, right: 4),
          color: c.background,
          child: Row(children: [
            Icon(icon, size: 15, color: c.textDim),
            const SizedBox(width: 8),
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Expanded(
              child: Text(title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: KitText.heading(context).copyWith(fontSize: 13)),
            ),
            if (action != null) action!,
          ]),
        ),
        const KitDivider(),
        Padding(padding: const EdgeInsets.all(12), child: child),
      ]),
    );
  }
}

String _toolLabel(String name) => switch (name) {
      'read_file' => 'Read',
      'write_file' => 'Write',
      'edit_file' => 'Edit',
      'list_dir' => 'List',
      'search' => 'Search',
      'run_command' => 'Run',
      'spawn_worker' => 'Spawned worker',
      'message_worker' => 'Messaged worker',
      'list_workers' => 'Checked workers',
      _ => name,
    };

IconData _toolIcon(String name) => switch (name) {
      'read_file' => Icons.description_outlined,
      'write_file' => Icons.note_add_outlined,
      'edit_file' => Icons.edit_outlined,
      'list_dir' => Icons.folder_open_outlined,
      'search' => Icons.search,
      'run_command' => Icons.terminal,
      'spawn_worker' => Icons.call_split,
      'message_worker' => Icons.forward_to_inbox_outlined,
      'list_workers' => Icons.list_alt,
      _ => Icons.build_outlined,
    };

String _toolSummary(Entry e, Project p) {
  final i = e.input ?? const {};
  switch (e.toolName) {
    case 'run_command':
      return i['command'] as String? ?? '';
    case 'search':
      return '${i['pattern'] ?? ''}${i['path'] == null ? '' : '  in ${i['path']}'}';
    case 'list_dir':
      return (i['path'] as String?)?.isNotEmpty == true ? i['path'] : '.';
    case 'spawn_worker':
      return i['title'] as String? ?? '';
    case 'message_worker':
      return p.thread(e.workerId ?? '')?.title ?? (i['worker_id'] as String? ?? '');
    case 'list_workers':
      return '';
    default:
      return i['path'] as String? ?? '';
  }
}

class ToolRow extends StatefulWidget {
  final MuseController controller;
  final Project project;
  final Entry entry;

  const ToolRow({super.key, required this.controller, required this.project, required this.entry});

  @override
  State<ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<ToolRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final e = widget.entry;
    final name = e.toolName ?? '';
    final asking = e.toolState == ToolState.awaitingApproval && widget.controller.isAwaitingApproval(e);
    final open = _open || asking;
    final worker = widget.project.thread(e.workerId ?? '');

    final Widget stateIcon = switch (e.toolState) {
      ToolState.running || ToolState.pending => const KitSpinner(size: 12),
      ToolState.awaitingApproval => Icon(Icons.pan_tool_outlined, size: 14, color: statusColor(c, ThreadStatus.waiting)),
      ToolState.error => Icon(Icons.close, size: 14, color: c.danger),
      ToolState.denied => Icon(Icons.block, size: 14, color: c.textDim),
      _ => Icon(Icons.check, size: 14, color: c.success),
    };

    final header = Pressable(
      onPressed: () => setState(() => _open = !_open),
      builder: (context, s) => Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: s.hovered ? c.hover : null,
          borderRadius: BorderRadius.circular(kitRadius),
        ),
        child: Row(children: [
          SizedBox(width: 16, child: Center(child: stateIcon)),
          const SizedBox(width: 8),
          Icon(_toolIcon(name), size: 15, color: c.textDim),
          const SizedBox(width: 6),
          Text(_toolLabel(name), style: KitText.body(context).copyWith(fontWeight: FontWeight.w500, fontSize: 13)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _toolSummary(e, widget.project).replaceAll('\n', ' '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: name == 'spawn_worker' || name == 'message_worker'
                  ? KitText.body(context).copyWith(fontSize: 13)
                  : monoStyle(context, size: 12).copyWith(color: c.textDim),
            ),
          ),
          if (worker != null) ...[
            const SizedBox(width: 6),
            StatusDot(worker.status),
            const SizedBox(width: 4),
            KitButton.ghost('Open', onPressed: () => widget.controller.selectThread(worker.id)),
          ],
          Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: c.textDim),
        ]),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      if (open)
        Padding(
          padding: const EdgeInsets.only(left: 32, top: 4, bottom: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            ..._details(context, e),
            if (asking) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                KitButton.primary('Allow',
                    icon: Icons.check,
                    onPressed: () => widget.controller.resolveApproval(widget.project, e, allow: true)),
                KitButton('Allow all in this project',
                    onPressed: () =>
                        widget.controller.resolveApproval(widget.project, e, allow: true, always: true)),
                KitButton.danger('Deny',
                    onPressed: () => widget.controller.resolveApproval(widget.project, e, allow: false)),
              ]),
            ],
          ]),
        ),
    ]);
  }

  List<Widget> _details(BuildContext context, Entry e) {
    final i = e.input ?? const {};
    final parts = <Widget>[];
    switch (e.toolName) {
      case 'write_file':
        parts.add(CodeBlock(_clip(i['content'] as String? ?? ''), language: i['path'] as String?));
      case 'edit_file':
        parts.add(_Diff(old: i['old_string'] as String? ?? '', replacement: i['new_string'] as String? ?? ''));
      case 'run_command':
        parts.add(CodeBlock(i['command'] as String? ?? '', language: 'command'));
      case 'spawn_worker':
        parts.add(Markdown(i['instructions'] as String? ?? ''));
      case 'message_worker':
        parts.add(Markdown(i['message'] as String? ?? ''));
      case 'read_file' || 'list_dir' || 'search' || 'list_workers':
        break;
      default:
        parts.add(CodeBlock(const JsonEncoder.withIndent('  ').convert(i)));
    }
    final out = e.output;
    if (out != null && out.isNotEmpty && e.toolName != 'spawn_worker' && e.toolName != 'message_worker') {
      if (parts.isNotEmpty) parts.add(const SizedBox(height: 6));
      parts.add(CodeBlock(_clip(out), language: e.toolState == ToolState.error ? 'error' : 'output'));
    }
    return parts;
  }

  static String _clip(String s) {
    final lines = s.split('\n');
    if (lines.length <= 60) return s;
    return '${lines.take(60).join('\n')}\n… ${lines.length - 60} more lines';
  }
}

class _Diff extends StatelessWidget {
  final String old;
  final String replacement;
  const _Diff({required this.old, required this.replacement});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    final style = monoStyle(context);
    Widget lines(String text, String sign, Color color) => Container(
          width: double.infinity,
          color: color.withValues(alpha: 0.12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            text.split('\n').take(40).map((l) => '$sign $l').join('\n'),
            style: style,
          ),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(kitRadius),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: c.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          lines(old, '-', c.danger),
          lines(replacement, '+', c.success),
        ]),
      ),
    );
  }
}
