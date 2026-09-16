# Penelope messaging — BACKGROUND → RESUME architecture

**Status:** Design review (no implementation until Jason locks)  
**Author:** Staff Architect  
**Date:** 2026-09-15 (America/Chicago)  
**Locks against:** `PENELOPE-MESSAGING-BACKGROUND-RESUME.md` (Chief UX)  
**Companion:** `PENELOPE-MESSAGING-LATENCY-STATES.md`, `docs/messaging-latency-diagnosis.md`  
**Repo:** `jcmcneal/penelope-bot`

---

## 1. Problem (product, not patch)

Today, any WS tear-down while a messaging live turn is active calls `MessagingStore.handleStreamDisconnected` → `MessagingLiveTurn.markDropped()`. If the overlay still has empty text/tools, the user sees:

> “The reply stream dropped. Waiting for the saved message…”

iOS **normally** tears down the socket on background. That is **transport interrupt**, not turn failure. Showing drop copy while Connected chrome can still look “up” is the Jason repro — and it violates UX anti-pattern: Connected + drop toast.

PR #12 (local Send ack + admit-time bind) improved first-token routing. It did **not** redefine disconnect semantics. This design does.

---

## 2. Design principles (locked to UX)

1. **Transport interrupt ≠ turn failure.** Local WS death (esp. on `scenePhase` background) must not alone emit drop copy or flip the turn to user-visible FAILED.
2. **One turn → one assistant bubble.** Stable client turn id (+ server run/session when known) spans background; catch-up merges into the same row.
3. **Silent by default; soft only when the wait is perceptible; honest only when sync proves loss.**
4. **Connected chrome = gateway/session truth**, not “is the local socket connected right now.”
5. **History remains authoritative** for final text (unchanged from #11 durable-wins). Overlay is a progress layer that must not lie about failure.

---

## 3. Conceptual model

### 3.1 Keep existing turn phases (product states)

`LOCAL_SENT` → `QUEUED` → `SHELL_READY` → `STREAMING` → `COMPLETE` | `FAILED` | `TOOL_APPROVAL`

Map these onto current `MessagingLiveTurn.phase` + conversation awaiting/delivery flags in the implementation plan (below). Do **not** invent a parallel UX vocabulary in UI strings.

### 3.2 Add lifecycle overlays (client-only)

| Overlay | Who sets it | User-visible? |
|---|---|---|
| `APP_BACKGROUND` | `scenePhase == .background` while a messaging turn is open | No (model only) |
| `RESUME_SYNC` | Foreground entry while turn open / unresolved | Silent unless soft threshold |
| `RECONNECTING` | Soft UI after ~800ms unresolved sync | Yes — calm line |
| `RESUMED_STREAM` | First post-resume proof of life (WS delta or history body) | Same bubble continues |
| `TURN_LOST` | Sync proved unrecoverable | Yes — honest error + Retry |

Overlays are **orthogonal** to turn phase. A turn can be `STREAMING` + `APP_BACKGROUND`, then `STREAMING` + `RESUME_SYNC`, then `STREAMING` with no overlay.

### 3.3 Classification: interrupt vs loss

| Signal | Class | Action |
|---|---|---|
| App backgrounded | Expected interrupt | Set `APP_BACKGROUND`; **do not** `markDropped` user copy |
| Local WS closed while backgrounded | Expected interrupt | Same |
| Local WS closed while foreground | Interrupt → enter `RESUME_SYNC` / reconnect schedule | Soft if slow; not drop copy yet |
| Run still `queued`/`running` in history after resume | Alive | Rebind sessions; clear soft UI |
| Completed assistant message for this turn in history | Success catch-up | `absorbHistory` into **same** bubble; clear overlays |
| No run, no saved assistant, after sync budget | `TURN_LOST` | Honest copy; keep user bubble |
| Gateway/session auth dead | Session disconnect | Disconnected chrome + existing repair — not Connected + drop |

---

## 4. Target state machine (resume slice)

```
  open turn (QUEUED | SHELL_READY | STREAMING | TOOL_APPROVAL)
           │
           ▼ scenePhase → background
    APP_BACKGROUND  (suppress drop copy; keep turn “in progress”)
           │
           ▼ scenePhase → active
      RESUME_SYNC
           │
           ├─ proof of life < ~800ms ──► silent ──► RESUMED_STREAM / COMPLETE
           ├─ still unresolved ≥ ~800ms ──► RECONNECTING (soft line)
           │         │
           │         ├─ proof of life ──► clear soft ──► RESUMED_STREAM / COMPLETE
           │         └─ sync proves gone ──► TURN_LOST
           └─ gateway/session dead ──► Disconnected chrome + recovery
```

**Hard rule:** `markDropped()` must **not** set the user-visible “stream dropped…” string solely because WS died. Either:
- remove that copy path for interrupt, or
- gate it behind `TURN_LOST` only (preferred: rename/split APIs — see §6).

---

## 5. Data & identity

### 5.1 Stable turn key (required for anti-duplicate)

Today live turns key mainly by `MessagingDestination.id` (`dm:profile` / `conversation:id`). That is necessary but not sufficient across reconnect if multiple runs could exist.

**Design:**

- Introduce an explicit **`clientTurnID`** (UUID) created at optimistic send (alongside pending message id).
- Persist with pending / live turn: `{ clientTurnID, conversationID?, runID?, sessionIDs, profileID }`.
- On resume: look up live turn by destination **and** `clientTurnID` (or single open turn per destination — today’s invariant for DMs).
- When send receipt / `messaging.run.start` / history runs arrive, attach `runID` + `sessionID` (admit-time bind from #12 stays).

**Invariant:** at most one open assistant overlay per destination; resume never creates a second overlay row for the same `clientTurnID`.

### 5.2 Proof of life (ordered preference)

1. WS event routed to this turn (token/tool/run start) after resume  
2. History shows active run for this conversation/profile with bindable session  
3. History shows completed assistant message for this turn window → absorb into same bubble  

Any one clears `RESUME_SYNC` / `RECONNECTING`.

---

## 6. Component responsibilities (surgical surface)

| Component | Today | Change |
|---|---|---|
| `AppState` disconnect handler | Calls `messagingStreamRouter.handleStreamDisconnected()` | Pass **reason**: `.background` / `.foregroundTransport` / `.sessionDead`. Do not treat all alike. |
| App / scene phase | (likely exists elsewhere) | On `.background` with open messaging turns: set overlay `APP_BACKGROUND`. On `.active`: start `RESUME_SYNC` + history refresh + WS reconnect (existing reconnect). |
| `MessagingStore.handleStreamDisconnected` | Always `markDropped()` all live turns | Split: `noteTransportInterrupt(reason:)` vs `failTurnIfLost(...)`. Background/local interrupt → no drop copy. |
| `MessagingLiveTurn.markDropped` | Sets drop string if empty | Replace with `markTransportInterrupted()` (no user string) and `markTurnLost(message:)` (honest copy only). |
| `MessagingConversationView` chrome | Shows `errorMessage` on interrupted | Soft line for `RECONNECTING`; hide interrupt; show lost only for `TURN_LOST`. |
| History poll / `absorbHistory` | Settles overlay | On resume, **urgent** poll until proof of life or loss budget (~3s). Clear soft UI on absorb. |
| Connected indicator | Tied to local `isConnected` in places | Messaging chrome: Connected iff gateway/session considered valid — not merely socket up. Brief local socket down during resume must not flicker Connected→error if session still valid. |

**Out of scope for this design PR (explicit):** TOOL_APPROVAL restore polish beyond “same turn + sheet if still paused”; nav Bots highlight; backend bot-coms protocol changes (use existing runs/history/WS). Flag if probe 8 needs a follow-up.

---

## 7. Timing budgets (implementation knobs)

| Knob | UX target | Proposed default |
|---|---|---|
| Soft reconnect UI delay | ~800–1000ms | 800ms after `RESUME_SYNC` without proof of life |
| Preferred proof of life | &lt;1.5s | Best-effort; soft OK to 3s |
| Turn-loss budget | ~3s after failed sync | 3s after resume sync started **and** history+reconnect attempted with no run/body |
| Cached thread paint | &lt;100ms | Already local store — do not clear transcript on resume |

These are client timers, not server SLAs.

---

## 8. Copy (from UX — do not invent alternatives in SWE)

| Situation | Copy |
|---|---|
| Silent interrupt | _(none)_ |
| Soft | “Catching up with the reply…” or “Reconnecting…” |
| Turn lost | “Couldn’t restore this reply. Retry?” |
| Avoid | “The reply stream dropped. Waiting for the saved message…” on interrupt paths |

Retry after `TURN_LOST` starts a **new** turn (new `clientTurnID`); never auto-spawn a duplicate assistant row for the lost one.

---

## 9. Risks & tradeoffs

| Risk | Mitigation |
|---|---|
| Soft UI flashes on every quick app switch | 800ms gate; silent path is default |
| Declaring TURN_LOST too early while server still running | Require history refresh + reconnect attempt; use run presence when destination known |
| Declaring success too late / limbo waiting chrome | Clear interrupt/soft on `absorbHistory`; never leave “waiting for saved…” as primary |
| Connected flicker | Decouple messaging header Connected from transient socket; use session validity |
| Breaking #11 isolation | Do **not** restore unkeyed alias-to-only-turn; resume bind uses destination + turn/run/session keys only |

---

## 10. Test plan (maps to UX probes 1–8)

Unit / store-level (no simulator UI required for core):

1. Background interrupt does **not** set drop copy on empty live turn.  
2. Foreground `RESUME_SYNC` → soft flag only after 800ms without proof of life.  
3. History absorb on resume clears soft/interrupt and keeps one bubble.  
4. Loss budget with empty history → `TURN_LOST` + Retry semantics.  
5. Gateway dead → session disconnect path, not Connected+drop.  
6. Rapid background/foreground → still one live turn per destination/`clientTurnID`.

UI probes 1–8 from UX doc = acceptance for QA / TestFlight after merge.

---

## 11. Implementation shape (when unlocked)

Single PR, messaging-focused:

1. Reason-typed transport interrupt API; kill interrupt→drop-copy path.  
2. Scene-phase hooks → overlays + resume sync (urgent history).  
3. Soft reconnect chrome (~800ms).  
4. `TURN_LOST` + Retry.  
5. Connected chrome honesty for messaging.  
6. Tests for §10.  
7. Update diagnosis doc with “implemented / remaining.”

Then `main` → `deploy` per Jason’s ship rule.

**Non-goals in that PR:** redesign of Sessions chat resume; ConnectionSetup flake fixes; backend changes.

---

## 12. Lock checklist (Jason)

- [ ] Agree: transport interrupt ≠ turn failure  
- [ ] Agree: soft threshold ~800ms; silent default  
- [ ] Agree: drop copy only on `TURN_LOST`  
- [ ] Agree: Connected ≠ local WS liveness for messaging chrome  
- [ ] Agree: one bubble / `clientTurnID` anti-dupe  
- [ ] Agree: probes 1–8 as acceptance  
- [ ] Unlock SWE (Cursor CLI) for one design-faithful PR  

**Open question for Jason (only if needed):** Soft line placement — under assistant shell vs under composer? UX allows either; default recommendation: **on the assistant shell** (keeps failure/reconnect near the turn, matches Night violet stream chrome).
