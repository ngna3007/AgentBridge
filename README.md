# AgentBridge

Local, file-based realtime bridge between two AI coding agents
(default pair: **Claude** and **Codex**). Coordinates messages,
acknowledgments, and per-file edit locks via append-only JSONL
on disk. No network listener, no broker, no cloud.

- **Transport:** append-only `messages.jsonl` + `events.jsonl`
- **Coordination:** filesystem locks (`O_EXCL`, heartbeat, TTL)
- **Spectator TUI:** `agentbridge ui` — live curses dashboard, one-key intervention
- **Agent verbs:** `handoff`, `ask`, `lock with-hold` cover ~90% of agent traffic
- **Live context:** optional tmux 4-pane topology
- **Durability:** atomic append (`fcntl.flock`) + `fsync`
- **Footprint:** single Python file (`scripts/agentbridge`), stdlib only

See [`AGENTBRIDGE_SPEC.md`](AGENTBRIDGE_SPEC.md) for the protocol spec
and [`Plans.md`](Plans.md) for the build plan and acceptance mapping.

---

## Install

No dependencies beyond Python 3.9+ and `tmux` (only for the tmux helper).

```bash
git clone <this-repo> AgentBridge
cd AgentBridge
make install           # symlinks scripts/agentbridge into /usr/local/bin
```

Or run directly without installing — every command works from
`scripts/agentbridge` in the repo.

## Quickstart

Two paths, depending on whether you're the human watching or an agent
sending.

### Human spectator (zero-flag path)

```bash
agentbridge init               # bootstrap .agent-bus/ in this dir
export AGENT_BRIDGE_IDENTITY=claude       # or codex — pick a side
export AGENT_BRIDGE_SESSION=demo          # any session id you like
agentbridge                    # bare invocation → launches the TUI
```

The bare `agentbridge` call on a TTY with an initialized bus opens
the curses dashboard: live message stream on the left, active locks
on the right, status line + key hints on the bottom. Press `?` for
help, `q` to quit. Keys: `s`end · `a`sk · `h`andoff · `t`ranscript ·
`j/k` scroll · `p`ause · `r`efresh · `g/G` jump.

The TUI is read-only by default — you watch the two agents
collaborate and only step in when you choose to.

### Agent path (3 verbs cover everything)

```bash
# hand off a task; optionally block until ack
agentbridge handoff --to codex --task "ship feature" --body "details" [--wait-ack]

# ask a question; blocks until an answer arrives (or --timeout)
reply=$(agentbridge ask --to codex --subject "which port?" --body "ssl listener?")

# edit a file under an auto-heartbeated, auto-released lock
agentbridge lock with-hold --path src/foo.rs -- $EDITOR src/foo.rs
```

`handoff --wait-ack` returns a JSON summary with the ack body. `ask`
prints just the answer body (`--json` for the full payload). `lock
with-hold` propagates the inner command's exit code and releases on
SIGINT/SIGTERM/normal exit — agents cannot leak locks.

Fall through to the raw `send` / `ack` / `lock acquire` primitives
only when the verbs above don't fit (fan-out, batched ops, scripted
retries).

### Smoke the whole pipeline

```bash
scripts/bootstrap.sh
```

### Onboard an agent in one line

```bash
agentbridge agent-prompt | pbcopy    # or | xclip -selection clipboard
```

Paste the result into the target agent's system prompt — it teaches
identity, session, sending, locks (including `with-hold`), and the
override protocol.

## Environment defaults

| Var                       | Effect                                                |
|---------------------------|-------------------------------------------------------|
| `AGENT_BRIDGE_IDENTITY`   | Default `--as`/`--from` when omitted                  |
| `AGENT_BRIDGE_SESSION`    | Default `--session` when omitted                      |
| `AGENT_BUS_DIR`           | Override `.agent-bus/` location                       |
| `AGENT_BRIDGE_NO_COLOR=1` | Disable ANSI color in pretty output                   |

---

## Bus layout

```text
.agent-bus/
  messages.jsonl        # task | question | answer | handoff | status | artifact | warning
  events.jsonl          # lock_acquired | lock_released | lock_heartbeat
                        # watch_started | ack_sent | stale_lock_reaped
                        # send_completed | corrupt_line_skipped | override_recorded
  locks/
    <key>.lock          # one file per locked path; see `lock key` for the normalizer
  sessions/
    <session>.<agent>.log
  state/
    claude.cursor
    codex.cursor
```

The bus root is `.agent-bus/` in the current working directory by default.
Override with `AGENT_BUS_DIR=/some/path`.

Permissions: `0700` on directories, `0600` on JSONL files.

---

## Commands

### `init`
Bootstrap the bus directory layout and apply restrictive permissions.
Idempotent: re-running on a populated bus only refreshes permissions
and prints `bus already initialized at <root>`.

### `ui`
```
ui [--as <agent>] [--session <id>]
```
Interactive curses spectator. Live message stream (color-coded by
type), active-lock pane, and modal forms for `s`end / `a`sk /
`h`andoff. Also reachable by bare `agentbridge` on a TTY with an
initialized bus. Keys (also in `?` modal):

| Key   | Action                              |
|-------|-------------------------------------|
| `s`   | send a status message               |
| `a`   | ask a question (`requires_ack`)     |
| `h`   | hand off a task                     |
| `t`   | open the transcript modal           |
| `j/k` | scroll message stream               |
| `g/G` | jump to oldest / newest             |
| `p`   | pause/resume live tail              |
| `r`   | force refresh                       |
| `?`   | help modal                          |
| `q`   | quit (ESC also works)               |

### `handoff` (composite)
```
handoff [--from <agent>] --to <agent> --task <subject>
        [--body <str> | --body-file <path|->]
        [--session <id>] [--priority <p>] [--tag <s>]...
        [--wait-ack] [--timeout <s>]
```
Wraps `send --type task` + optional ack-wait. Without `--wait-ack`
prints the new message UUID and exits. With `--wait-ack`, blocks
up to `--timeout` (default 300s) and prints a JSON summary:
`{handoff_id, ack_id, ack_from, ack_body}`. Exits 1 on timeout.

### `ask` (composite)
```
ask [--from <agent>] --to <agent> --subject <str>
    [--body <str> | --body-file <path|->]
    [--session <id>] [--priority <p>] [--tag <s>]...
    [--timeout <s>] [--json]
```
Wraps `send --type question --ack` + blocking ack-wait. Prints the
answer body on stdout (or full message JSON with `--json`). Exits 1
on timeout.

### `send`
```
send [--from <agent>] --to <agent>
     --type {task|question|answer|handoff|status|artifact|warning}
     --subject <str> [--body <str> | --body-file <path|-> ]
     [--session <id>] [--ack]
     [--reply-to <uuid>] [--priority {low|normal|high}]
     [--tag <s>]... [--artifact kind=...,ref=...[,sha256=...]]...
```
Appends a validated message to `messages.jsonl`, emits `send_completed`
event, prints the new message UUID on stdout. `--body-file -` reads
the body from stdin (handy for multi-line content or piping diffs).
`--from`/`--session` fall back to `AGENT_BRIDGE_IDENTITY`/`AGENT_BRIDGE_SESSION`.
Self-message (`--from == --to`) and unknown `--reply-to` UUIDs are
rejected at the CLI boundary.

### `watch`
```
watch [--as <agent>] [--session <id>] [--interval <ms>] [--once]
      [--pretty | --json] [--bell]
```
Tails `messages.jsonl` for messages addressed to `--as`, filtered by
`--session` if provided. Maintains the byte-offset cursor at
`.agent-bus/state/<agent>.cursor`. `--once` drains pending and exits.
On a TTY, output defaults to a colored pretty form
(`ts  from→to  [type]  subject`); use `--json` to force raw JSONL,
`--pretty` to force pretty in pipes. `--bell` rings the terminal on
each new message. Corrupt JSONL lines are skipped and emit a
`corrupt_line_skipped` event recording the byte offset.

### `inbox`
```
inbox [--as <agent>] [--session <id>] [--unread]
      [--type <t>] [--needs-ack] [--pretty | --json]
```
One-shot lister for messages addressed to `--as`. `--unread` honors
the cursor (so it shows only messages newer than the last `watch`
position) but does not advance it. Filter by `--type` or restrict to
those with `requires_ack: true` via `--needs-ack`.

### `ack`
```
ack [--as <agent>] --reply-to <msg-id> [--body <str>]
```
Sends an `answer`-type reply linked to the original via `reply_to`.
Restricted to the original message's recipient. Emits `ack_sent`.

### `lock`
```
lock acquire   [--as <agent>] --path <repo-rel-path>
               [--ttl <s>] [--reason <str>] [--wait <s>]
lock heartbeat [--as <agent>] --path <repo-rel-path>
lock release   [--as <agent>] --path <repo-rel-path> [--force]
lock reap      [--as <agent>] --path <repo-rel-path>
               [--force-stale] [--window <s>]
lock key       <repo-rel-path>
lock with-hold [--as <agent>] --path <repo-rel-path>
               [--ttl <s>] [--interval <s>] [--reason <str>]
               -- <cmd> [args...]
```
Lock key normalization: lowercase, leading `./` stripped, each path
component has its `_` escaped to `_5f`, then components joined with
`__`. So `a/b__c` → `a__b_5f_5fc` (distinct from `a__b__c` →
`a_5f_5fb_5f_5fc`). The `lock key` subcommand prints the normalized
key for any path (handy for tagging warnings or grepping
`events.jsonl`). Absolute paths and `..` segments are rejected —
repo-relative only.

Lock file is created with `O_EXCL` (first-writer-wins). `lock acquire
--wait <s>` polls until the slot frees or the deadline expires.
Stale check: `now - heartbeat_at > ttl_seconds`. Stale locks may be
reaped freely. **Non-stale override** (`reap --force-stale`) requires
a prior `warning` message from the reaper to the lock owner, tagged
with `override:<lock_key>` within `--window` seconds (default 60). An
`override_recorded` event is emitted referencing the warning message.

`lock with-hold` is the recommended wrapper for guarded edits: it
acquires the lock, spawns a background heartbeat thread, runs your
inner command, and releases on normal exit, SIGINT, or SIGTERM. The
inner command's exit code is propagated.

```bash
agentbridge lock with-hold --path src/app.py --ttl 30 -- \
    bash -c "cargo fmt -- src/app.py && cargo check"
```

### `transcript`
```
transcript [--session <id>] [--format {pretty|jsonl}]
```
Merges `messages.jsonl` and `events.jsonl` by timestamp into a
chronological timeline. Deterministic and reproducible. JSON output
is one entry per line with a `kind` field (`msg` | `evt`).

### `tmux`
```
tmux --session <id> [--name <tmux-session-name>]
```
Spawns a tmux session with four panes:
1. Claude shell (logged to `sessions/<id>.claude.log` via `script(1)`)
2. Codex shell (logged to `sessions/<id>.codex.log`)
3. `watch --as claude --session <id>`
4. `watch --as codex --session <id>`

Requires `tmux` on `PATH`. Reusing the same name kills the prior session.

### `status`
Prints bus root, message/event counts, active locks (with staleness),
and cursor positions.

### `agent-prompt`
Prints a copy-paste system-prompt snippet teaching another agent how
to talk to AgentBridge: identity/session env vars, the `send`/`ack`
contract, lock etiquette (including `with-hold`), and the override
protocol. Picks up `AGENT_BRIDGE_IDENTITY`/`AGENT_BRIDGE_SESSION` for
its examples so the prompt is pre-personalized.

### `version`
Prints `agentbridge <semver>` and exits 0.

### `cursor`
```
cursor show  [--as <agent>]
cursor reset [--as <agent>] [--to <byte-offset>]
```
Inspect or reset the per-agent watch cursor. `reset` without `--to`
removes the cursor file (next `watch`/`inbox --unread` starts from
offset 0). Useful after manually trimming `messages.jsonl` or if a
cursor desyncs.

### `completion`
```
completion {bash|zsh}
```
Emits a self-contained completion script.
```bash
# bash
agentbridge completion bash > ~/.local/share/bash-completion/completions/agentbridge
# zsh
agentbridge completion zsh > "${fpath[1]}/_agentbridge" && compinit
```
Tab-completes top-level commands, `lock`/`cursor` subcommands, agent
names, message types, priorities, and file paths.

### Dry-run send

`send --dry-run` validates and prints the message JSON without
appending it to `messages.jsonl` or emitting `send_completed`. Use it
when composing complex payloads from inside an agent before
committing.

---

## Message schema

```jsonc
{
  "id": "uuid-v4",
  "ts": "ISO-8601 UTC (e.g. 2026-05-27T00:00:00.000Z)",
  "session_id": "free-form session id (e.g. eng-1792)",
  "from": "claude|codex",
  "to":   "claude|codex",
  "type": "task|question|answer|handoff|status|artifact|warning",
  "subject": "short string",
  "body":    "markdown/plain text payload",
  "requires_ack": true,
  "reply_to": "optional original-message uuid",
  "priority": "low|normal|high",
  "tags": ["..."],
  "artifacts": [
    { "kind": "file|diff|command-output|url", "ref": "path-or-url", "sha256": "optional" }
  ]
}
```

## Event schema

```jsonc
{
  "id": "uuid-v4",
  "ts": "ISO-8601 UTC",
  "session_id": "...",
  "actor": "claude|codex|agentbridge",
  "event": "lock_acquired|lock_released|lock_heartbeat|watch_started|ack_sent|stale_lock_reaped|send_completed|corrupt_line_skipped|override_recorded",
  "meta":  { "path": "...", "lock_id": "...", "...": "..." }
}
```

---

## Failure model

| Failure                     | Recovery                                                                   |
|-----------------------------|----------------------------------------------------------------------------|
| Watcher killed mid-stream   | Restart `watch`; cursor file resumes from last consumed offset             |
| Corrupted JSONL line        | Watcher skips line, emits `corrupt_line_skipped` event with `byte_offset`  |
| Lock owner crashed          | Heartbeat ages out; other agent runs `lock reap`                           |
| Non-stale lock contention   | Owner-priority: requester sends `question`+`requires_ack`, owner responds  |
| Emergency override          | Reaper must first send `warning` msg tagged `override:<key>`, then `--force-stale` |

**Filesystem requirement:** the bus directory must live on a local
POSIX filesystem. Atomic-append relies on `fcntl.flock()` and `O_APPEND`
semantics that are not honored consistently on NFS or SMB shares —
running the bus across a network mount can produce torn lines and
lock corruption. Use a local path (default `./.agent-bus/`) or a
tmpfs / btrfs / ext4 / apfs / xfs volume.

---

## Tests

```bash
tests/run_all.sh
```

Suite:
- `test_delivery.sh`   — N msgs delivered, median latency <1s, ack contract (AC1/AC2)
- `test_contention.sh` — 8 parallel acquires → exactly 1 wins; release; reap; override gate (AC3)
- `test_crash.sh`      — kill -9 watcher, restart, exactly-once in-order delivery; corrupt line skipped (AC4)
- `test_transcript.sh` — timeline reproducible across reruns; deterministic ordering (AC5)
- `test_security.sh`   — `0700`/`0600` perms; no listener; static no-net source check; secret scanner
- `test_ux.sh`         — env defaults; `--pretty`/`--json`; `inbox`; `--body-file`; `lock key`/`with-hold`/`--wait`; abs-path/self-msg/reply-to guards; `agent-prompt`; `version`
- `test_lock_key.sh`   — lock-key normalizer: `..` rejection, leading `./` strip, underscore-escape collision-freedom, absolute-path rejection

---

## Acceptance criteria → test coverage

| ID  | Spec acceptance criterion                                  | Covered by                  |
|-----|------------------------------------------------------------|-----------------------------|
| AC1 | Local send → receive within 1 second                       | `test_delivery.sh`          |
| AC2 | `requires_ack` always produces ack                         | `test_delivery.sh`          |
| AC3 | Concurrent same-file edits blocked by lock protocol        | `test_contention.sh`        |
| AC4 | Crash + restart never drops unread messages                | `test_crash.sh`             |
| AC5 | Session transcript reproducible from JSONL logs            | `test_transcript.sh`        |

---

## Security model

- Local-only. No network listeners in the MVP.
- Bus directory `0700`, JSONL files `0600`, lock files `0600`.
- Secrets must be passed by reference (`artifact.ref`), never inline.
- A simple secret-pattern scanner is included in `test_security.sh`;
  integrate it into a `send` pre-flight hook if you want hard blocking.

---

## Upgrade path (V2: WebSocket broker)

The schema and lock semantics are designed to lift unchanged onto a
broker process. The JSONL files remain the durable write-ahead log;
the broker would simply replay/relay over a `ws://` channel with
auth tokens and per-session topics. A small web UI can render the
existing `transcript` output as a timeline.

---

## License

MIT (or your preferred OSI license — none committed yet).
