# Session cache

Aether's native loopback route demuxes the source into temporary fMP4 segments
under `<tmp>/aether-segments/<session-uuid>`. This is a playback mechanism and a
current-session seek/read-ahead cache, not offline storage. A successful stop,
source replacement, or failed load removes the entire UUID directory. A later
session never reads or adopts its media bytes.

## Configuring the policy

`LoadOptions.forwardBufferSegments` controls the producer/cache window and
`LoadOptions.sessionCacheByteBudget` controls its requested byte ceiling:

```swift
// Window-only: temporary segments required for playback still exist.
let disabled = LoadOptions(
    forwardBufferSegments: 4,
    sessionCacheByteBudget: 0
)

// Adaptive 512-MB current-session target.
let automatic = LoadOptions(
    forwardBufferSegments: 10,
    sessionCacheByteBudget: 512 << 20
)

// Aggressive prefetch under an 8-GiB current-session target.
let disk = LoadOptions(
    forwardBufferSegments: Int.max,
    sessionCacheByteBudget: 8 << 30
)
```

The engine normalizes a negative request to zero. It then clamps the request to
one quarter of available temporary-volume capacity. If volume capacity cannot
be read, an explicit request remains subject to a conservative 2-GiB ceiling.
The automatic nil policy preserves the historical 2-GiB default, or relaxes
that default cap for an explicitly large forward window while retaining the
quarter-free volume guard.

The byte request cannot evict segments in the active hard playback window. If
those actual bytes exceed the clamped request, playback wins: the producer may
always maintain its minimum safe lead, and `effectiveBudgetBytes` rises to the
hard-window bytes with `hardWindowFloorExceeded == true`. No per-segment size
estimate is used. Aggressive prefetch parks at its base effective byte budget
once the consumer has a safe lead and resumes as the playhead advances.

## Observing the policy

Read `engine.sessionCacheStatus`, or observe
`engine.diagnostics.$sessionCacheStatus` for lifecycle and 1-Hz active updates.
The snapshot reports:

- route and capability (`loopback_fmp4` is active; `native_remote_hls` is
  unsupported because AVPlayer/the origin owns that buffering);
- requested, volume-safety, base-effective, playback-floor and final-effective
  byte values;
- current resident and forward bytes, configured windows, producer parked
  state and eviction count;
- typed disk failure plus cleanup reason/result.

`currentResidentBytes` is a footprint, not a promise that every time position
from the beginning through that byte count is seekable. Use the engine's
buffered/seekable time surfaces for timeline UI.

## Lifecycle and failure behavior

The current directory is removed after the producer has stopped using it.
Cleanup is typed as `session_stopped`, `source_changed`, or `load_failed`.
Write/adopt failures fail closed: no nonexistent file is added to byte or index
accounting, and normal playback recovery handles the resulting cache miss.

On startup, Aether inspects at most 128 sibling entries and deletes at most 16
directories older than one hour. It never deletes the current UUID or a fresh
sibling. Crash remnants are never reused and are handled only by later bounded
sweeps.
