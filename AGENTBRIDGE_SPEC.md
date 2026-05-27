# AgentBridge — Claude ↔ Codex Realtime Bridge Spec (MVP)

## Goal
Enable Claude and Codex to exchange structured messages in near realtime, coordinate file edits safely, and share live terminal context without requiring cloud services.

## Non-Goals
- No direct model-to-model socket integration.
- No centralized SaaS backend.
- No automatic merge/conflict resolution beyond lock protocol.

## Architecture (MVP)
Local-first, file-based bus + optional tmux panes.

- Transport: append-only JSONL mailbox.
- Coordination: filesystem lock files.
- Observability: transcript + event log.
- Live context: tmux panes streaming each agent output.

## Directory Layout
```text
.agent-bus/
  messages.jsonl
  events.jsonl
  locks/
    <normalized-file-path>.lock
  sessions/
    <session-id>.json
  state/
    claude.cursor
    codex.cursor
scripts/
  agentbridge
```

## Message Schema (messages.jsonl)
Each line = one JSON object.

```json
{
  "id": "uuid-v4",
  "ts": "2026-05-27T00:00:00.000Z",
  "session_id": "eng-1792",
  "from": "claude",
  "to": "codex",
  "type": "task|question|answer|handoff|status|artifact|warning",
  "subject": "short title",
  "body": "markdown/plain text payload",
  "artifacts": [
    {
      "kind": "file|diff|command-output|url",
      "ref": "path-or-url",
      "sha256": "optional"
    }
  ],
  "requires_ack": true,
  "reply_to": "optional-message-id",
  "priority": "low|normal|high",
  "tags": ["eng-1792", "audit-chain"]
}
```

## Event Schema (events.jsonl)
For protocol/system actions.

```json
{
  "id": "uuid-v4",
  "ts": "2026-05-27T00:00:00.000Z",
  "session_id": "eng-1792",
  "actor": "claude|codex|agentbridge",
  "event": "lock_acquired|lock_released|watch_started|watch_crashed|ack_sent|stale_lock_reaped",
  "meta": {
    "path": "apps/api-rs/src/http/admin_audit.rs",
    "lock_id": "optional"
  }
}
```

## Lock Protocol
### Lock key
- Normalize repo-relative path:
  - lower-case
  - `/` separators
  - replace `/` with `__`
- File: `.agent-bus/locks/<key>.lock`

### Lock file body
```json
{
  "lock_id": "uuid-v4",
  "owner": "claude|codex",
  "path": "repo/relative/path",
  "acquired_at": "2026-05-27T00:00:00.000Z",
  "heartbeat_at": "2026-05-27T00:00:10.000Z",
  "ttl_seconds": 120,
  "reason": "editing hash canonicalization"
}
```

### Rules
1. Agent MUST acquire lock before editing file.
2. If lock exists and not stale, other agent MUST not edit.
3. Lock owner heartbeats every 20s.
4. Lock stale if `now - heartbeat_at > ttl_seconds`.
5. Stale lock can be reaped with event log entry.
6. Locks released immediately after write batch.

## Conflict Rules
- Same-file contention: first valid lock wins.
- Cross-file dependency contention: requester sends `question` + `requires_ack` to owner.
- Emergency override allowed only with explicit `warning` message + event log.

## Agent Command Set (agentbridge)
### `agentbridge send`
```bash
agentbridge send --from claude --to codex --type task --subject "Verify hash parity" --body "Compare Rust vs SQL payload strings" --session eng-1792 --ack
```

### `agentbridge watch`
```bash
agentbridge watch --as claude --session eng-1792
```
- Tails messages for recipient.
- Maintains cursor in `.agent-bus/state/claude.cursor`.

### `agentbridge ack`
```bash
agentbridge ack --as codex --reply-to <message-id> --body "Received. Running checks."
```

### `agentbridge lock acquire`
```bash
agentbridge lock acquire --as claude --path apps/api-rs/src/http/admin_audit.rs --ttl 120 --reason "patch verify logic"
```

### `agentbridge lock heartbeat`
```bash
agentbridge lock heartbeat --as claude --path apps/api-rs/src/http/admin_audit.rs
```

### `agentbridge lock release`
```bash
agentbridge lock release --as claude --path apps/api-rs/src/http/admin_audit.rs
```

### `agentbridge lock reap`
```bash
agentbridge lock reap --as codex --path apps/api-rs/src/http/admin_audit.rs --force-stale
```

## Realtime Terminal Sharing (Optional tmux)
### Pane topology
- Pane 1: Claude session output
- Pane 2: Codex session output
- Pane 3: `agentbridge watch --as claude`
- Pane 4: `agentbridge watch --as codex`

### Logging
- Pipe pane outputs to:
  - `.agent-bus/sessions/<session-id>.claude.log`
  - `.agent-bus/sessions/<session-id>.codex.log`

## Failure Recovery
1. **Watcher crash**
   - Restart `agentbridge watch`.
   - Resume from cursor file.
2. **Stale lock**
   - Reap stale lock.
   - Emit `stale_lock_reaped` event.
3. **Corrupted JSONL line**
   - Skip invalid line.
   - Emit `warning` event with byte offset.
4. **Clock skew issues**
   - Prefer monotonic process time for local stale checks where possible.

## Security Model (Local-only)
- Bus directory permissions: `0700`.
- Lock/message files owned by local user only.
- No network listener in MVP.
- Secrets must not be sent in message body; share references only.
- Optional content redaction hook before `send` writes.

## 10-Minute Bootstrap (WSL/Linux)
```bash
mkdir -p .agent-bus/{locks,sessions,state}
: > .agent-bus/messages.jsonl
: > .agent-bus/events.jsonl
chmod -R 700 .agent-bus
```

Then implement `scripts/agentbridge` (Python or Node), start two watches, and exchange first task/ack.

## Upgrade Path (V2 WebSocket Broker)
Keep same schema and lock semantics.

- Add broker process relaying JSON messages over ws.
- Keep JSONL as durable write-ahead log.
- Add auth token + per-session channels.
- Add simple web UI for timeline + lock state.

## Acceptance Criteria
1. Claude sends task; Codex receives within 1s on local machine.
2. Requires-ack messages always produce ack.
3. Concurrent same-file edits blocked by lock protocol.
4. Crash + restart does not lose unread messages.
5. Session transcript reproducible from JSONL logs.
