# Host request identity and timeline observation

This additive integration patch preserves `seek(to:)`, its scheduling and return
timing. A host that needs causal correlation can use
`await engine.seek(to: seconds, requestID: UUID())` and subscribe to `seekEvents`
before calling it. Supply a fresh UUID for every new logical request.

`SeekEvent.requestID` is optional. Legacy callers and independent engine actions
use nil. The UUID survives loading/readiness deferral and replay, rejection,
supersession and a stalled attempt's late result. `SeekEvent.id` continues to
identify an engine attempt: a deferred request and its replay have different
attempt IDs but the same request UUID. An attempt's `superseded` event does not
necessarily terminate the logical request. Neither identifier authorizes retries
or substitutes for the host's media/lease ownership checks.

For a coherent position value, subscribe to `engine.clock.$timelineObservation`.
The immutable value contains:

- `sessionEpoch` and `revision`: lifecycle and update ordering within this engine.
- `positionSeconds`: optional position on the display/session axis used by seek
  input and duration. Unknown positions are nil, not zero.
- `sampledAtUptime`: monotonic process uptime when the actual clock was read.
- `evidence`: `nativePresentationClock`, `softwarePresentationClock`,
  `softwareReanchoredClock`, `heldLastSample`, or `unavailable`.
- `seekInFlight` and `seekRecoveryPending`: separate facts; recovery can outlive
  the public seek call and the in-flight level.

Status-only updates retain a held sample's original timestamp. Native item
attachment, software host replacement and teardown invalidate prior samples.
Callbacks are fenced against retired host/item lifetimes. Subscribers should
consume the emitted value instead of joining separate `@Published` properties
inside their `willSet` callbacks.

Native samples come from actual AVPlayer clock reads, with the engine's existing
display-axis mapping. Assigning a target to a published scalar does not itself
create a sample. Software samples capture one existing synchronizer timer read
and its source-to-session mapping together. After a software seek reanchor,
`softwareReanchoredClock` conservatively persists for that host's lifetime:
existing callbacks do not prove which post-seek video frame replaced the old one.

All clock evidence describes a clock, **not a per-frame physical display
receipt**. Readiness, packet/frame submission, a successful API return and a
software demux reposition must not be promoted to that stronger guarantee. This
patch does not alter the historical `SeekEvent.Outcome` cases or renderer,
decoder, audio reload, seek recovery or transport behavior.

This observation adapter currently covers native loopback and software Direct
Play VOD. Live, remote-HLS bypass and audio-only routes remain unavailable here;
the interface does not infer mappings for them. Existing APIs for those routes
remain unchanged. New source clients must rebuild the package; this is not a
binary ABI compatibility promise.

Validation for the patch includes request/event, deferred replay, held freshness,
epoch, nonfinite input, software reanchor and axis regression tests. Hostless
tests do not establish device picture landing. The integrating tvOS project's
REN-091H documentation owns device and UI acceptance, separately from these
library checks.
