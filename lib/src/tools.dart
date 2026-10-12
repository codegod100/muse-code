/// Tool definitions and system prompts for the orchestrator and workers.
library;

Map<String, dynamic> _tool(String name, String description, Map<String, dynamic> properties,
        [List<String> required = const []]) =>
    {
      'name': name,
      'description': description,
      'input_schema': {
        'type': 'object',
        'properties': properties,
        'required': required,
      },
    };

final readFileTool = _tool(
  'read_file',
  'Read a text file in the project, with line numbers. Paths are relative to the project folder.',
  {
    'path': {'type': 'string'},
    'offset': {'type': 'integer', 'description': '1-based line to start at.'},
    'limit': {'type': 'integer', 'description': 'How many lines to read (default 2000).'},
  },
  ['path'],
);

final listDirTool = _tool(
  'list_dir',
  'List a directory in the project. Directories end in /. Omit path for the project folder.',
  {'path': {'type': 'string'}},
);

final searchTool = _tool(
  'search',
  'Search file contents in the project with a regular expression. Skips .git, build and dependency folders. '
      'Returns path:line: text for up to 200 matches.',
  {
    'pattern': {'type': 'string'},
    'path': {'type': 'string', 'description': 'Directory to search, default the project folder.'},
    'ignore_case': {'type': 'boolean'},
  },
  ['pattern'],
);

final writeFileTool = _tool(
  'write_file',
  'Create or overwrite a file with the given content. Creates missing directories.',
  {
    'path': {'type': 'string'},
    'content': {'type': 'string'},
  },
  ['path', 'content'],
);

final editFileTool = _tool(
  'edit_file',
  'Replace old_string with new_string in a file. old_string must match exactly and be unique unless '
      'replace_all is set. Read the file first.',
  {
    'path': {'type': 'string'},
    'old_string': {'type': 'string'},
    'new_string': {'type': 'string'},
    'replace_all': {'type': 'boolean'},
  },
  ['path', 'old_string', 'new_string'],
);

final runCommandTool = _tool(
  'run_command',
  'Run a shell command in the project folder (bash on Linux and macOS, cmd on Windows) and return its '
      'combined output and exit code. Use it for builds, tests, git and other CLI tools. Not interactive.',
  {
    'command': {'type': 'string'},
    'timeout_seconds': {'type': 'integer', 'description': 'Default 120, at most 600.'},
  },
  ['command'],
);

final spawnWorkerTool = _tool(
  'spawn_worker',
  'Start a worker thread on one task. The worker cannot see this conversation, so the instructions must '
      'be complete: the goal, relevant files or context, constraints, and what to report back. Returns '
      'at once; the worker\'s report arrives later as a <worker_report> message.',
  {
    'title': {'type': 'string', 'description': 'A few words naming the task, shown in the thread list.'},
    'instructions': {'type': 'string'},
  },
  ['title', 'instructions'],
);

final messageWorkerTool = _tool(
  'message_worker',
  'Send a follow-up to an existing worker, such as a user\'s follow-up about its task or a correction. '
      'The worker keeps its full context. Its next report arrives as a <worker_report> message.',
  {
    'worker_id': {'type': 'string'},
    'message': {'type': 'string'},
  },
  ['worker_id', 'message'],
);

final listWorkersTool = _tool(
  'list_workers',
  'List this project\'s workers with their ids, titles and status.',
  {},
);

/// Tools that change things and so ask first unless the project allows
/// them.
const mutatingTools = {'write_file', 'edit_file', 'run_command'};

/// Tools the orchestrator handles itself rather than the host.
const orchestrationTools = {'spawn_worker', 'message_worker', 'list_workers'};

List<Map<String, dynamic>> orchestratorTools({required bool files}) => [
      spawnWorkerTool,
      messageWorkerTool,
      listWorkersTool,
      if (files) ...[readFileTool, listDirTool, searchTool],
    ];

List<Map<String, dynamic>> workerTools({required bool files}) => files
    ? [readFileTool, listDirTool, searchTool, writeFileTool, editFileTool, runCommandTool]
    : [];

String orchestratorPrompt({required String project, required String root}) => '''
You are the orchestrator for the project "$project" in Muse Code, a coding assistant. You work in the project's main thread, where the user talks to you. ${root.isEmpty ? 'This project has no folder on disk, so workers can only reason and write in their replies.' : 'The project folder is $root.'}

You don't edit files or run commands yourself. You turn what the user asks for into focused tasks and hand each one to a worker thread with spawn_worker, then keep the user informed.

- Give each distinct piece of work its own worker, with a short title and complete, self-contained instructions. Workers can't see this conversation.
- Run independent tasks in parallel workers. When one task depends on another, wait for the first report before spawning the next.
- When the user follows up on work a worker already owns, forward it with message_worker rather than starting a new worker.
- Answer questions you can answer from the conversation directly. ${root.isEmpty ? '' : 'Use read_file, list_dir and search for quick looks, not for doing the work.'}
- Worker reports arrive as <worker_report> messages. When one arrives, tell the user the outcome in a sentence or two and dispatch any follow-up work it calls for.
- Keep replies short and plain. The user can open any worker thread to see the details.
''';

String workerPrompt({required String project, required String root, required String title}) => '''
You are a worker in Muse Code, working on the project "$project". Your thread is "$title". ${root.isEmpty ? 'This project has no folder on disk, so you have no file or command tools: do the task in your reply.' : 'The project folder is $root; tool paths are relative to it.'}

You were given one task, by the project's orchestrator or by the user directly. Work until it is done: inspect the code before changing it, make the change, and check it where you can (run the tests, the build, or the program). Ask nothing you can find out yourself.

Finish with a short report: what you did, the files you changed, what you checked and how it went, and anything left open. That final message goes back to the orchestrator.
''';
