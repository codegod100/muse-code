import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../anthropic.dart';
import 'host.dart';

Host createHost() => IoHost();

const _maxOutput = 30000;
const _skipDirs = {'.git', 'node_modules', 'build', '.dart_tool', '.pixi', '.venv', '__pycache__', 'target'};

String _truncate(String s, {bool keepEnd = false}) {
  if (s.length <= _maxOutput) return s;
  final cut = s.length - _maxOutput;
  return keepEnd
      ? '[… $cut characters cut …]\n${s.substring(cut)}'
      : '${s.substring(0, _maxOutput)}\n[… $cut characters cut …]';
}

class IoHost implements Host {
  /// Overrides the state file, for tests.
  final String? statePath;

  IoHost({this.statePath});

  @override
  bool get hasFiles => true;

  @override
  String? get envApiKey {
    final key = Platform.environment['ANTHROPIC_API_KEY'];
    return key == null || key.isEmpty ? null : key;
  }

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

  @override
  bool directoryExists(String path) => path.isNotEmpty && Directory(path).existsSync();

  @override
  Future<ToolResult> runTool(String name, Map<String, dynamic> input,
      {required String root, required CancelToken cancel}) async {
    if (root.isEmpty || !Directory(root).existsSync()) {
      return const ToolResult.error('This project has no folder, so there are no files to work with.');
    }
    try {
      return switch (name) {
        'read_file' => await _read(root, input),
        'write_file' => await _write(root, input),
        'edit_file' => await _edit(root, input),
        'list_dir' => await _list(root, input),
        'search' => await _search(root, input, cancel),
        'run_command' => await _run(root, input, cancel),
        _ => ToolResult.error('Unknown tool $name'),
      };
    } on _PathError catch (e) {
      return ToolResult.error(e.message);
    } on FileSystemException catch (e) {
      return ToolResult.error('${e.message}${e.path == null ? '' : ': ${e.path}'}');
    }
  }

  /// Resolves [path] against the project folder and refuses anything
  /// outside it.
  String _resolve(String root, Object? path) {
    final p = (path as String? ?? '').trim();
    final rootUri = Directory(root).absolute.uri;
    final resolved = p.isEmpty ? rootUri : rootUri.resolve(p.replaceAll('\\', '/'));
    final out = resolved.toFilePath();
    final rootPath = rootUri.toFilePath();
    final trimmedRoot = rootPath.endsWith(Platform.pathSeparator)
        ? rootPath.substring(0, rootPath.length - 1)
        : rootPath;
    if (out != rootPath && out != trimmedRoot && !out.startsWith(rootPath)) {
      throw _PathError('$p is outside the project folder.');
    }
    return out;
  }

  String _relative(String root, String path) {
    final rootPath = Directory(root).absolute.uri.toFilePath();
    return path.startsWith(rootPath) ? path.substring(rootPath.length) : path;
  }

  Future<ToolResult> _read(String root, Map<String, dynamic> input) async {
    final f = File(_resolve(root, input['path']));
    if (!await f.exists()) return ToolResult.error('No such file: ${input['path']}');
    final lines = const LineSplitter().convert(await f.readAsString());
    final offset = ((input['offset'] as num?)?.toInt() ?? 1).clamp(1, lines.length + 1);
    final limit = (input['limit'] as num?)?.toInt() ?? 2000;
    final end = (offset - 1 + limit).clamp(0, lines.length);
    final out = StringBuffer();
    for (var i = offset - 1; i < end; i++) {
      var line = lines[i];
      if (line.length > 2000) line = '${line.substring(0, 2000)}…';
      out.writeln('${(i + 1).toString().padLeft(5)}  $line');
    }
    if (end < lines.length) out.writeln('[${lines.length - end} more lines; read with offset ${end + 1}]');
    if (lines.isEmpty) out.write('(empty file)');
    return ToolResult(_truncate(out.toString()));
  }

  Future<ToolResult> _write(String root, Map<String, dynamic> input) async {
    final f = File(_resolve(root, input['path']));
    final content = input['content'] as String? ?? '';
    final existed = await f.exists();
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    final lines = '\n'.allMatches(content).length + (content.isEmpty ? 0 : 1);
    return ToolResult('${existed ? 'Overwrote' : 'Created'} ${input['path']} ($lines lines).');
  }

  Future<ToolResult> _edit(String root, Map<String, dynamic> input) async {
    final f = File(_resolve(root, input['path']));
    if (!await f.exists()) return ToolResult.error('No such file: ${input['path']}');
    final old = input['old_string'] as String? ?? '';
    final replacement = input['new_string'] as String? ?? '';
    final all = input['replace_all'] == true;
    if (old.isEmpty) return const ToolResult.error('old_string is empty.');
    final text = await f.readAsString();
    final count = old.allMatches(text).length;
    if (count == 0) return const ToolResult.error('old_string was not found in the file.');
    if (count > 1 && !all) {
      return ToolResult.error(
          'old_string appears $count times; add surrounding lines to make it unique, or set replace_all.');
    }
    await f.writeAsString(all ? text.replaceAll(old, replacement) : text.replaceFirst(old, replacement));
    return ToolResult('Edited ${input['path']} ($count ${count == 1 ? 'change' : 'changes'}).');
  }

  Future<ToolResult> _list(String root, Map<String, dynamic> input) async {
    final dir = Directory(_resolve(root, input['path']));
    if (!await dir.exists()) return ToolResult.error('No such directory: ${input['path'] ?? '.'}');
    final items = await dir.list().toList();
    final names = [
      for (final e in items) e is Directory ? '${e.uri.pathSegments.reversed.skip(1).first}/' : e.uri.pathSegments.last
    ]..sort((a, b) {
        final ad = a.endsWith('/'), bd = b.endsWith('/');
        if (ad != bd) return ad ? -1 : 1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    if (names.isEmpty) return const ToolResult('(empty directory)');
    final shown = names.take(500).join('\n');
    return ToolResult(names.length > 500 ? '$shown\n[${names.length - 500} more]' : shown);
  }

  Future<ToolResult> _search(String root, Map<String, dynamic> input, CancelToken cancel) async {
    final RegExp re;
    try {
      re = RegExp(input['pattern'] as String? ?? '', caseSensitive: input['ignore_case'] != true);
    } on FormatException catch (e) {
      return ToolResult.error('Bad pattern: ${e.message}');
    }
    final start = _resolve(root, input['path']);
    final out = <String>[];
    Future<void> walk(Directory d) async {
      await for (final e in d.list(followLinks: false)) {
        if (cancel.isCancelled || out.length >= 200) return;
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is Directory) {
          if (!_skipDirs.contains(name)) await walk(e);
        } else if (e is File) {
          if (await e.length() > 1 << 20) continue;
          final String text;
          try {
            text = await e.readAsString();
          } catch (_) {
            continue; // Binary or not UTF-8.
          }
          final lines = const LineSplitter().convert(text);
          for (var i = 0; i < lines.length && out.length < 200; i++) {
            if (re.hasMatch(lines[i])) {
              final line = lines[i].length > 300 ? '${lines[i].substring(0, 300)}…' : lines[i];
              out.add('${_relative(root, e.path)}:${i + 1}: ${line.trim()}');
            }
          }
        }
      }
    }

    if (await FileSystemEntity.isDirectory(start)) {
      await walk(Directory(start));
    } else {
      return const ToolResult.error('path must be a directory.');
    }
    if (out.isEmpty) return const ToolResult('No matches.');
    return ToolResult(out.length >= 200 ? '${out.join('\n')}\n[stopped at 200 matches]' : out.join('\n'));
  }

  Future<ToolResult> _run(String root, Map<String, dynamic> input, CancelToken cancel) async {
    final command = input['command'] as String? ?? '';
    if (command.trim().isEmpty) return const ToolResult.error('command is empty.');
    final timeout = Duration(seconds: ((input['timeout_seconds'] as num?)?.toInt() ?? 120).clamp(1, 600));
    final process = Platform.isWindows
        ? await Process.start('cmd', ['/c', command], workingDirectory: root)
        : await Process.start('bash', ['-lc', command], workingDirectory: root);
    final out = StringBuffer();
    final done = Completer<void>();
    var pending = 2;
    void listen(Stream<List<int>> s) => s.transform(const Utf8Decoder(allowMalformed: true)).listen(
          out.write,
          onDone: () {
            if (--pending == 0 && !done.isCompleted) done.complete();
          },
        );
    listen(process.stdout);
    listen(process.stderr);
    var killedFor = '';
    final unregister = cancel.onCancel(() {
      killedFor = 'stopped';
      process.kill(ProcessSignal.sigkill);
    });
    final timer = Timer(timeout, () {
      killedFor = 'timed out after ${timeout.inSeconds}s';
      process.kill(ProcessSignal.sigkill);
    });
    final code = await process.exitCode;
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    timer.cancel();
    unregister();
    final text = _truncate(out.toString().trimRight(), keepEnd: true);
    if (killedFor.isNotEmpty) return ToolResult.error('${text.isEmpty ? '' : '$text\n'}[$killedFor]');
    final body = text.isEmpty ? '(no output)' : text;
    return code == 0 ? ToolResult(body) : ToolResult.error('$body\n[exit code $code]');
  }
}

class _PathError implements Exception {
  final String message;
  _PathError(this.message);
}
