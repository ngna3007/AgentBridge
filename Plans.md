# AgentBridge — Claude↔Codex Realtime Bridge Plans.md

Created: 2026-05-27

---

## Phase 1: Foundation and Protocol Core

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 1.1 | Create bus bootstrap structure (`.agent-bus/{locks,sessions,state}` + `messages.jsonl` + `events.jsonl`) and permissions (`0700`). | Running bootstrap command creates exact directory/file layout and `stat` confirms restrictive permissions. | - | cc:DONE |
| 1.2 | Define and implement strict message/event JSON schema validators in `scripts/agentbridge` (required fields, enum values, timestamps, UUID format). | Invalid payload rejected with clear error; valid payload appended successfully; unit checks cover pass/fail samples. | 1.1 | cc:DONE |
| 1.3 | Implement atomic JSONL append utility with corruption-safe write behavior and fsync policy for durability. | Concurrent sends do not interleave JSON lines; every appended line is valid JSON object; append utility reused by send/ack/event writers. | 1.2 | cc:DONE |
| 1.4 | Implement message send command (`agentbridge send`) with `requires_ack`, `reply_to`, `priority`, and artifacts fields. | Command writes message matching schema and appears in `messages.jsonl` with generated UUID and timestamp. | 1.3 | cc:DONE |

## Phase 2: Watchers, Cursor, and Ack Reliability

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 2.1 | Implement per-agent cursor persistence (`.agent-bus/state/claude.cursor`, `codex.cursor`) and unread scanning logic. | Watch restart resumes from cursor and does not re-deliver previously consumed messages. | 1.4 | cc:DONE |
| 2.2 | Implement `agentbridge watch --as <agent> --session <id>` filtering by recipient/session and handling corrupted lines with warning events. | Watch outputs only matching messages, skips malformed line, and writes warning event with byte offset metadata. | 2.1 | cc:DONE |
| 2.3 | Implement `agentbridge ack` flow and delivery contract for `requires_ack=true` messages. | For each ack-required message, receiver can emit ack linked by `reply_to`; ack appears within local workflow test. | 2.2 | cc:DONE |
| 2.4 | Add watcher crash recovery script/path and prove recovery from abrupt termination. | Kill watcher, restart watcher, unread messages still delivered in order from cursor position. | 2.2 | cc:DONE |

## Phase 3: Lock Protocol and Contention Safety

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 3.1 | Implement lock key normalization (`lowercase`, `/` normalization, `__` mapping) and lock file creation format. | Same repo path always maps to same lock file key; lock body matches spec fields exactly. | 1.3 | cc:DONE |
| 3.2 | Implement `lock acquire/release` semantics with first-writer-wins enforcement for same file. | Second agent cannot acquire non-stale lock; release removes lock and emits corresponding event lines. | 3.1 | cc:DONE |
| 3.3 | Implement heartbeat updates and stale detection (`now - heartbeat_at > ttl_seconds`) plus reap command. | Heartbeat extends lock liveness; stale lock can be reaped; `stale_lock_reaped` event logged. | 3.2 | cc:DONE |
| 3.4 | Implement emergency override guardrail (`warning` message + event entry required) and verify protocol behavior. | Override path rejected without warning+event evidence; accepted when both present and recorded. | 3.3 | cc:DONE |

## Phase 4: Observability and Transcript Reproducibility

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 4.1 | Ensure all protocol actions emit structured events (`watch_started`, `ack_sent`, `lock_*`, crash/reap warnings). | Event log contains complete lifecycle entries for send/watch/ack/lock operations in sample run. | 2.3, 3.4 | cc:DONE |
| 4.2 | Build session transcript reconstruction utility from JSONL logs (message timeline + event timeline). | Running reconstruction on sample session reproduces ordered chain of task/question/answer/ack and lock events. | 4.1 | cc:DONE |
| 4.3 | Add optional tmux topology helper (4 panes) and session log piping to `.agent-bus/sessions/<session-id>.*.log`. | Helper creates expected panes and writes Claude/Codex logs to session files when enabled. | 2.2 | cc:DONE |

## Phase 5: Acceptance and Hardening

| Task | Description | DoD | Depends | Status |
|------|------|-----|---------|--------|
| 5.1 | Build acceptance test script for <1s local delivery target and ack contract. [tdd:required] | Script asserts message arrives to watcher within 1s median local run and ack-required messages produce ack records. | 2.3 | cc:DONE |
| 5.2 | Build contention test for concurrent same-file edit lock blocking. [tdd:required] | Parallel acquire attempts show first lock wins and second fails until release or stale reap. | 3.2 | cc:DONE |
| 5.3 | Build crash/restart reliability test using cursor persistence. [tdd:required] | After watcher kill/restart, unread messages still delivered exactly once in order. | 2.4 | cc:DONE |
| 5.4 | Build transcript reproducibility test from logs. [tdd:required] | Reconstructed transcript matches deterministic expected chain from fixture session logs. | 4.2 | cc:DONE |
| 5.5 | Final security/local-only checks: no network listener, no secrets in message payload fixtures, permission checks. | Verification script confirms no listening socket in MVP flow, warns on secret-like payload patterns, and enforces 0700 bus dir. | 5.1, 5.2, 5.3, 5.4 | cc:DONE |

---

## Suggested Execution Order

1. Phase 1 complete before any watcher work.
2. Phase 2 and Phase 3 can proceed partially in parallel after Phase 1.4.
3. Phase 4 starts after core watch+lock behaviors are stable.
4. Phase 5 validates all acceptance criteria from spec.

## Acceptance Mapping to Spec

- AC1 (<1s delivery): Task 5.1
- AC2 (requires-ack always ack): Tasks 2.3, 5.1
- AC3 (same-file edit blocked): Tasks 3.2, 5.2
- AC4 (crash restart no unread loss): Tasks 2.4, 5.3
- AC5 (transcript reproducible): Tasks 4.2, 5.4

---

## MVP completion status (2026-05-27)

All Phase 1–5 tasks `cc:DONE`. Deliverables shipped:
- `scripts/agentbridge` — single-file Python CLI (stdlib only).
- `scripts/bootstrap.sh` — 10-min sanity script per spec.
- `tests/` — 5 test suites, 1 runner, 31+ assertions.
- `README.md`, `Makefile`, `.gitignore`.

Measured: median local delivery latency ~85ms (1s budget).
Atomic-append holds under 24-way concurrent send. Lock first-writer-wins
verified over 8 parallel acquires. Override guardrail enforces
`warning`-msg-then-`--force-stale` chain. Crash/restart loses zero
unread messages and skips corrupt JSONL lines with byte-offset
warnings. Transcript reconstruction is deterministic across reruns.

Next milestones (V2, not in MVP):
- WebSocket broker over the existing schema.
- Web UI rendering `transcript --format jsonl`.
- Hook-based content redaction before `send` writes.
- Per-session auth tokens.

---

## Phase 6 — UX polish (2026-05-27, `cc:DONE`)

Post-MVP UX review shipped — agentbridge bumped to `0.2.0`.

- 6.1 Env defaults: `AGENT_BRIDGE_IDENTITY`, `AGENT_BRIDGE_SESSION`.
  `--as`/`--from`/`--session` now optional when env is set.
- 6.2 `watch --pretty` / `--json` / `--bell`; TTY auto-pretty with
  ANSI color (suppressed by `AGENT_BRIDGE_NO_COLOR`).
- 6.3 `inbox` subcommand — one-shot view with `--unread`, `--type`,
  `--needs-ack` filters. Does not advance the watcher cursor.
- 6.4 `send --body-file <path|->` — file or stdin body (multi-line
  diffs, prompts).
- 6.5 `send` boundary checks: self-message refused; `--reply-to`
  validated against existing message UUID.
- 6.6 `lock key <path>` helper exposes the normalized key. Absolute
  / escaping paths rejected with a clear "repo-relative" error.
- 6.7 `lock acquire --wait <s>` polling loop replaces manual retry.
- 6.8 `lock with-hold ... -- <cmd>` — auto heartbeat thread + signal
  handlers; releases on normal exit, SIGINT, SIGTERM.
- 6.9 `agent-prompt` — copy-paste system-prompt snippet pre-filled
  from env, teaches identity/session/locks/override.
- 6.10 `version` subcommand; `init` prints next-step hints on TTY.
- 6.11 `tests/test_ux.sh` — 28 assertions covering all of the above;
  added to `tests/run_all.sh`.
