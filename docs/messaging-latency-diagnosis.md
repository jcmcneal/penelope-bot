# Penelope / Hermes Conduit — messaging architecture diagnosis

**Role:** Staff Architect (read-only)  
**Date:** 2026-09-15 (America/Chicago)  
**Checkout intent:** `/Users/jason/projects/penelope-bot` on Jasons-iMac (`0d03658b-…`)  
**Actual source used:** `jcmcneal/penelope-bot` **main** via raw GitHub (same public tree as the fork). Cursor CLI / machineId Shell+Read were **not available** in this subagent session (`cursor` MCP missing; `machineId` on Shell ignored → box hostname `cursor`). No git mutations; no code fixes.

**UX acceptance frame:** `PENELOPE-MESSAGING-LATENCY-STATES.md` (Chief UX) — states LOCAL_SENT / QUEUED / SHELL_READY / STREAMING / COMPLETE / FAILED / TOOL_APPROVAL; budgets &lt;100ms send ack, &lt;300ms shell.

---

## 1. End-to-end messaging architecture map

```
ComposerBar.submit()
  ├─ collapseSubmittedDraft()          // UI text clear (sync)
  └─ Task → MessagingConversationStore.send()
        ├─ pending = PendingMessagingSend   // LOCAL_SENT optimistic bubble
        ├─ MessagingStore.startLiveTurn()   // shell phase=.starting
        ├─ beginAwaitingReply()             // 1s poll window, 20s dots timeout
        └─ await MessagingService.send()    // POST …/messages (network)
              └─ historyCache.accept(receipt)  // user msg into durable cache
                    └─ Task load() history     // runs[] + messages (poll)
                          └─ syncLiveTurn()    // bind session_id from runs; absorbHistory

Parallel (if WS connected):
  HermesClient WS firehose
    → StreamEventParser + StreamJoinKey(conversation_id, run_id, profile_id)
    → AppState.handleStreamEvent(event, join)
         ├─ if eventBelongsToActiveSession → ChatView applyStreamEvent (Sessions path)
         └─ else messagingStreamRouter.handleUnboundStreamEvent
              → MessagingStore.routeKey(join | profile | sessionIDs)
              → MessagingLiveTurn.apply (tokens/tools)
              → MessagingConversationView.liveTurnChrome / StreamingBubble

Settle:
  History poll (4s idle / 1s urgent / 250ms while needsFastHistorySettle)
  → absorbHistory() replaces overlay text; settledTextInHistory hides stream bubble
```

### Key Swift types / files

| Layer | Types / files |
|---|---|
| Send / conversation VM | `MessagingConversationStore` — pending, sending, poll cadence, `send`/`accepted` |
| HTTP API | `MessagingService` — `/dms|conversations/…/messages`, history |
| Cache | `MessagingHistoryCache`, `MessagingTranscriptProjection`; docs `docs/chat-history-cache.md` |
| Live overlay | `MessagingLiveTurn`, `MessagingStore` (`liveTurns`, `handleUnboundStreamEvent`) |
| Join routing | `StreamJoinKey`, `StreamEventParser` (`messaging.run.start`) |
| Transport | `HermesClient` WS; reconnect owned by `AppState` |
| Fan-out | `AppState.handleStreamEvent` → active session **or** `messagingStreamRouter` |
| UI | `MessagingConversationView`, `ComposerBar` + `MessagingComposerAdapter`, `StreamingBubble`/`StreamingText` |
| Shell / nav | `AppShellState.messagingDestination`, `RootView`, `SidebarTab` (Bots) |
| Models | `MessagingModels` (`MessagingRun.sessionID`, receipt = conversation+message only) |

**Important:** Bot messaging is **not** the Sessions `sendMessage` path. It is bot-coms HTTP + optional unbound WS overlay. Backend design (`docs/design/messaging-runtime-redesign.md`) still describes worker → fresh `hermes chat` → public transcript; streaming UX depends on gateway firehose join keys + client overlay.

---

## 2. Top concrete causes (slowness & glitch) → UX targets broken

### A. Perceived slowness

| # | Cause | Evidence | Breaks |
|---|---|---|---|
| A1 | **Send ACK / Send re-enable tied to HTTP**, not local | `send` sets `pending` then `await submit` → network. `MessagingComposerAction` keeps Send `.unavailable` while `hasPending \|\| isSending`. Receipt has no runs. | LOCAL_SENT “brief disable”; probe 1 partial (bubble OK, cool-down not local) |
| A2 | **First tokens often wait on history poll, not WS** | After PR #11, `routeKey` needs `join.conversationID` / `join.profileID` / overlapping `sessionIDs`. `startLiveTurn` sets **no** sessionIDs. `messaging.run.start` only helps if already routed. Send receipt **omits** runs/session. Binding typically waits `load()` → `syncLiveTurn` from `MessagingRun.sessionID`. Until then unbound deltas are **dropped**. | SHELL_READY→token; STREAMING; probe 2 (shell dots may show, but live text late → blank→dump) |
| A3 | **Dual settle path: WS overlay + 1s/250ms history poll** | `historyPollInterval` 4s / 1s urgent / **250ms** when `needsFastHistorySettle`. Doc: queued/running keep 1s polling. Extra main-actor churn + late absorb. | STREAMING smoothness; COMPLETE settle; probe 3/6 |
| A4 | **Backend execution still “finish then public transcript” shaped** | Design doc: worker quiet-mode stdout → public reply; streaming is client overlay on shared WS. Cold/join-miss path = poll until durable message. | First paint / time-to-token |

### B. Buggy / glitchy behavior

| # | Cause | Evidence | Breaks |
|---|---|---|---|
| B1 | **Join-key routing without safe single-turn fallback** | PR #10 added alias-onto-only-active-turn; PR #11 **removed** it (cross-talk on busy gateway). Correct for isolation, but if plugin omits join fields, overlay stays empty until history — then `absorbHistory` snaps full text. | STREAMING; probe 2/4; flicker QUEUED⇄STREAMING⇄COMPLETE |
| B2 | **Overlay vs durable race (partially fixed)** | PR #11: durable wins (`absorbHistory` always replaces; tools from foreign sessions rejected; `message.complete` overwrites diverged text). Residual: mid-stream 250ms polls + `onChange(of: liveTurn)` scroll pulses can still thrash layout. | STREAMING stability; probe 3; anti-reflow |
| B3 | **No TOOL_APPROVAL surface on messaging path** | `MessagingLiveTurn.apply` ignores `.approval` / `.clarify`. Design doc: “Conduit does not yet present native tool-approval prompts” for messaging. | TOOL_APPROVAL; probe 5 (mute lock / hang) |
| B4 | **State chrome not 1:1 with UX state machine** | Phases: `starting/streaming/usingTool/completing/interrupted/failed` + separate `awaitingReply` dots + `MessagingRunPresence`. Overlay vs presence mutually exclusive (`showsLiveTurnOverlay`). Easy flicker between dots / avatar presence / stream bubble. | State clarity; anti-glitch #2 |
| B5 | **Reasoning not shown as soft secondary in bot thread** | `reasoning` accumulated on turn; `liveTurnChrome` only tools + text/dots — no REASONING_SOFT row. | REASONING_SOFT |
| B6 | **Nav: chat under Bots chrome** | `RootView` back label “Bots”; `messagingDestination` overlay; sidebar tab stays Bots. Matches UX soft-watch. | Nav / identity contract |
| B7 | **WS disconnect → interrupted overlay, then poll settle** | `handleStreamDisconnected` → `markDropped`; UI may show error then history absorb clears it — ghost streaming / error flash. | COMPLETE/FAILED honesty; probe 4/6 |
| B8 | **Optimistic bubble opacity 0.85 until receipt merges** | Intentional pending chrome; if HTTP slow, bubble stays “ghost” while Send locked. | LOCAL_SENT polish |

---

## 3. What PR #10 / #11 fixed vs remaining holes

### PR #10 — `bots-streaming-snappy` (“Stream bot replies…”)
**Fixed:** End of “wait for finished public transcript only.” Added `MessagingLiveTurn` overlay, tool cards, composer stays usable (Send gated on pending only), socket reuse across profile switch, settle onto history if stream drops, `MessagingRun.sessionID`, haptics, tests. Later commits: tool parse split, don’t steal chat resume events, stop AnyView remounts breaking settled Markdown, then **alias live WS session onto unique active overlay**.

### PR #11 — `messaging-run-join`
**Fixed:** Cross-wiring on busy gateway by routing on `conversation_id` / `run_id` / `profile_id`; removed only-active-turn alias. Second commit: **saved assistant wins** over scrambled overlay; foreign tools don’t attach; completing overlay no longer keeps spinner after durable text.

### Remaining holes
1. **Cold bind gap:** no session/join on turn at send → early WS events dropped until history/runs.  
2. **Gateway contract dependency:** client assumes join keys on firehose; weak/absent keys → poll-only UX (feels pre-#10).  
3. **Send receipt too thin:** no run/session → cannot SHELL_READY-bind at HTTP ack.  
4. **Approval / clarify** still dead on messaging overlay.  
5. **UX state machine / budgets** not modeled (QUEUED vs SHELL_READY; &lt;100ms Send cool-down).  
6. **Nav highlight** and Figma static-only Send/stream still craft gaps (not fixed by #10/#11).

---

## 4. Ranked next moves (impact vs risk) — surgical preferred

| Rank | Move | Impact | Risk | Closes |
|---|---|---|---|---|
| 1 | **Bind overlay at admit time:** extend send receipt (or push `messaging.run.start` with join) to include `run_id` + `session_id` + `conversation_id`; `startLiveTurn`/`accepted` bind immediately | High TTFT / kill blank→dump | Med (API + server) | A2, B1, probe 2/4 |
| 2 | **Local Send completion:** clear pending-wait for Send cool-down independently of HTTP (keep pending bubble + reconcile); treat network failure as FAILED without removing bubble silently | High LOCAL_SENT feel | Low–med | A1, probe 1 |
| 3 | **Verify/enforce join keys on every bot-coms WS event**; client assert/metrics when liveTurns active but routeKey nil | High reliability | Low | A2, B1 |
| 4 | **Narrow history poll:** avoid 250ms unless necessary; coalesce liveTurn `@Published` updates (throttle UI) | Med jank | Low | A3, B2, probe 3 |
| 5 | **Map phases → UX states** in one chrome component (queued stub / shell / streaming / complete / failed); kill dual dots+presence flicker | Med “glitchy” | Low | B4 |
| 6 | **Messaging approval sheet** on `.approval` (reuse Chat approval) | Med trust | Med | B3, probe 5 |
| 7 | Soft reasoning line under stream | Low–med | Low | B5 |
| 8 | Nav: distinct chat destination highlight vs Bots | Low craft | Low | B6 |

Avoid: restoring global “alias only active turn” without join keys (reopens cross-talk). Prefer **keyed bind** or **receipt bind**.

---

## 5. UX probe pass/fail (architecture prediction)

| Probe | Verdict | Why |
|---|---|---|
| 1 Optimistic send (kill network) | **PARTIAL PASS** | Bubble from `pending` + composer collapse sync. Send stays unavailable while `hasPending`; failed HTTP 4xx clears pending+liveTurn (bubble may vanish); unknownOutcome may leave pending + “Check delivery”. Not clean FAILED. |
| 2 Shell before tokens (2s delay) | **PARTIAL PASS** | `startLiveTurn` → empty shell + dots immediately (better than waiting run accept). True streaming shell into **same** bubble only after join/session bind; else dots then history dump. |
| 3 Stable stream | **PARTIAL / FAIL under load** | Append-only on one `MessagingLiveTurn` when routed. Poll absorb + liveTurn onChange scroll + Markdown streaming can thrash. |
| 4 Run-join / reconnect | **PARTIAL PASS** | Join keys + syncLiveTurn from runs intended for same bubble. Disconnect marks interrupted; no duplicate turn by design. Missed early events → gap then absorb (not true resume). |
| 5 Tool pause → sheet | **FAIL** | `.approval` ignored on messaging overlay. |
| 6 Complete settle | **PARTIAL PASS** | `settledTextInHistory` + shouldDrop improved by #11. Risk of ghost streaming if runs linger or tools running; reconnect error flash. |

**Budget flags:** LOCAL_SENT bubble likely &lt;100ms; Send re-enable **often &gt;100ms** (HTTP). SHELL dots &lt;300ms local; **first token** often **&gt;1s** when join/session bind lags.

---

## 6. Architect summary (≤12 lines — paste to Jason)

Penelope bot DMs send over bot-coms HTTP with an optimistic user bubble, then paint replies via a **WS stream overlay** (`MessagingLiveTurn`) settled by **history poll**—not the Sessions chat pipeline.  
PRs #10/#11 made streaming real and stopped busy-gateway cross-talk + scrambled overlays (durable text wins).  
What’s still slow/glitchy: **early WS tokens drop** until join keys or `runs.session_id` bind; send receipt has **no run/session**, so shell can sit on dots then **snap full text**.  
Send cool-down is **network-gated** (`hasPending`), not a local &lt;100ms ack.  
No messaging **TOOL_APPROVAL** UI; approval events are ignored.  
Chrome flickers across awaiting-dots / run-presence / overlay phases; Bots nav stays highlighted in-thread.  
Highest leverage: **admit-time bind** (receipt or `messaging.run.start`+join) + local Send ack; then throttle poll/UI; then approval sheet.  
Do **not** bring back unkeyed alias-to-only-turn.

---

## Access note for parent

- **Cursor CLI on iMac:** not executed — this subagent cannot reach machineId `0d03658b-…` (`ListMachines` / `cursor` MCP unavailable; Shell+machineId runs on box).  
- Fallback: public `main` sources + UX doc copy at `/workspace/conduit-ux/PENELOPE-MESSAGING-LATENCY-STATES.md`.  
- Artifacts: `/workspace/penelope-diag/` (sources snapshot, PR patches, this report).  
- If parent re-runs with working machine routing: confirm iMac HEAD == analyzed main; spot-check live WS payloads for `conversation_id`/`profile_id` on bot turns.
