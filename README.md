# Muse Code

A desktop coding assistant built on flatkit, in the spirit of Claude Code
but organised around projects and threads.

Each project points at a folder and has a **Main** thread with an
orchestrator in it. You tell the orchestrator what you want; it splits the
work into tasks and starts a **worker thread** for each one. Workers read,
search and edit files and run commands in the project folder, then report
back. Reports land in Main as cards, and the orchestrator reads them, tells
you the outcome and hands out any follow-up work. Follow-ups about a task go
to the worker that owns it, and you can open any worker and talk to it
directly.

- Workers run in parallel and show their status in the thread list:
  working, needs approval, done, failed or stopped.
- Edits and commands ask first, with Allow, Allow all in this project and
  Deny on the tool call. Turn asking off per project in its settings.
- Replies stream in, tool calls expand to show their input and output, and
  edits show as a diff.
- Projects, threads and settings are saved between runs
  (`~/.config/muse_code/state.json` on Linux).

## Running it

```sh
cd apps/muse_code
flutter pub get
flutter run -d linux     # or macos, windows
```

Add your Anthropic API key in Settings (it starts with `sk-ant-` and is sent
as the `x-api-key` header to api.anthropic.com only), or set
`ANTHROPIC_API_KEY` before starting the app. The orchestrator and workers use
Claude Opus 5.5 by default; the model for each and the effort level are in
Settings.

The web build (`flutter run -d chrome`) works for chat-only projects: the
browser has no folder to work in, so workers have no file or command tools
there, and state lasts only as long as the tab.

## How it fits together

- `lib/src/engine.dart`: the thread loop, orchestrator tools
  (`spawn_worker`, `message_worker`, `list_workers`), approvals, report
  delivery and saving.
- `lib/src/anthropic.dart`: a streaming Messages API client (Dart has no
  official SDK), keeping thinking blocks so history is passed back intact.
- `lib/src/tools.dart`: tool schemas and the orchestrator and worker
  prompts.
- `lib/src/host/`: file and shell tools and state storage for desktop, with a
  stub for the web.
- `lib/src/ui/`: the window, transcript, dialogs and a small Markdown
  renderer, all flatkit widgets.

```sh
flutter test
```
