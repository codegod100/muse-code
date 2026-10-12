# Muse Code

A GUI for [Meta's Muse Code](https://meta-models.github.io/muse-code-sdk),
built on flatkit and organised around projects and threads, in the spirit
of Claude Code. Muse runs in the cloud; nothing executes on your machine.

A project is created from a name. It gets its own workspace on the cloud
host, and you attach git repositories to it afterwards (project menu →
Repositories); each one is cloned into the workspace.

Each project has a **Main** thread backed by a Muse session whose agent
orchestrates: it plans, and starts a Muse subagent for each independent
piece of work. Every subagent shows up as a **worker thread** you can open,
follow live and message directly. When a worker finishes, its result lands
in Main as a report card and the orchestrator carries on.

- Worker status in the thread list: working, needs approval, done, failed
  or stopped.
- Approvals come from Muse with its own choices (Allow once, Allow for this
  session, Reject, …). Turn asking off per project from its menu.
- Replies stream in; tool calls expand to show their input, output and
  edits.
- The app keeps its view of projects and threads between runs
  (`~/.config/muse_code/state.json` on Linux) and replays anything it missed
  from Muse when it reconnects.

## How it fits together

```
 Muse Code app  ──WebSocket (MSP frames)──▶  relay  ──stdio──▶  muse serve
 (desktop/web)  ──HTTPS (projects, repos)─▶  (cloud)            (+ git, workspaces)
```

`muse serve` speaks the Muse Session Protocol (MSP), JSON-RPC 2.0 over
stdio. The relay (`relay/`) runs next to it in a container: it bridges the
app's WebSocket to the host, keeps one folder per project, and clones
attached repos into it.

- `lib/src/msp.dart`: the MSP client (requests, commands with UUIDv7
  `commandId`s, notifications, host requests such as `approval/request`).
- `lib/src/engine.dart`: sessions per project, turns, subagents → worker
  threads, approvals, reconnect and replay.
- `lib/src/relay_api.dart`: project workspaces and repos on the relay.
- `lib/src/ui/`: the window, transcript, dialogs and a small Markdown
  renderer, all flatkit widgets.

## Running the relay

```sh
cd apps/muse_code/relay
docker build -t muse-relay .
docker run -p 8080:8080 -v muse-workspaces:/workspaces -v muse-home:/root/.local/share/muse \
  -e META_API_KEY=... -e MUSE_RELAY_TOKEN=$(openssl rand -hex 24) muse-relay
```

| Variable | What it is |
| --- | --- |
| `META_API_KEY` or `MUSE_API_KEY` | Meta Muse API key (dev.meta.ai). Handed to Muse as `META_API_KEY`; it never leaves the relay. Muse gets no other secrets from the relay's environment. |
| `MUSE_RELAY_TOKEN` | A random secret, at least 16 characters. The app sends it as `Authorization: Bearer <token>`, and as the `bearer.<token>` WebSocket subprotocol. |
| `GITHUB_TOKEN` or `GITHUB_API_TOKEN` | Optional, for private GitHub repos (fine-grained, Contents read/write). |
| `MUSE_WORKSPACES` | Where project folders live, default `/workspaces`. |
| `PORT` | Default `8080`. |

Put it behind HTTPS in production (any container host works).

## Running the app

```sh
cd apps/muse_code
flutter pub get
flutter run -d linux     # or macos, windows, chrome
```

In Settings, enter the relay URL and the relay token. On the web build,
state lasts only as long as the tab.

## Tests

```sh
flutter test                       # app, against Muse's recorded MSP sessions
cd relay && dart test              # relay
```

`test/fixtures/msp/` holds conformance transcripts from the Muse SDK
repository, replayed as a stand-in host.
