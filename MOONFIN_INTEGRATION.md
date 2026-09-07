# Moonfin tvOS Integration

This public fork carries AetherEngine changes required by the Moonfin tvOS
application.

## Upstream submissions — 2026-09-07

The user approved three independent PRs against canonical main
`1af43f017ffca973e35f8fec1e700852f2953d55`:

- [#510: recovery-point VOD compatibility](https://github.com/superuser404notfound/AetherEngine/pull/510),
  `36789677cc290632e0cefd3504e7d32b6964b3a3`.
- [#511: Matroska H.264 timestamp ownership](https://github.com/superuser404notfound/AetherEngine/pull/511),
  `f0c01de34003bd45347d5562f2ed47d18ba544b8`.
- [#512: retained software VOD read-ahead/cache-local seeks](https://github.com/superuser404notfound/AetherEngine/pull/512),
  `1f96ea33c02efe09892cc9bd2241853ac6395746`.

Each is a single scoped commit on its own pushed fork branch, with docs and
regressions. The cache port uses upstream's existing budget policy rather than
this fork's host-specific settings; Matroska diagnostics use an internal summary.
No host UI or private media/log data is submitted. All three isolated tvOS
package builds and focused standalone checks passed. Full upstream CI currently
awaits maintainer approval (14:54 Asia/Shanghai), not a failed test.

The accepted runtime on this branch and the installed candidate 20260907140332
remain unchanged; the host stays pinned to `8b3001c85d38512c14ed7a06e5db441372c62220`.
This entry is documentation only. Earlier candidate/pending entries below are
historical; later acceptance records and the linked PR test plans state the final
results and their limits. No pushed history or rollback tag was rewritten.

## 6.71.0 integration verification

- Software VOD packet-cache candidate (2026-09-07): the user confirms all three
  recovery-point assets now seek smoothly on the compatibility route, but its
  decoded-only buffer frontier hid the previous ahead-of-playhead bar. Seekable
  software VOD now prefetches compressed AVPackets into a chunked temporary FIFO,
  preserving PTS, DTS, duration, stream/flags, byte position, timebase and every
  side-data entry. Actual selected A/V PTS coverage is intersected for the existing
  bufferedPosition interface; missing intervals are never filled by a bitrate or
  DTS estimate. The native forward-window and quarter-of-free-volume budget
  helpers are reused; renderer queues remain short. Seek retires the old FIFO
  generation, and stop/abandoned-session cleanup is bounded and session-scoped.
  This is forward read-ahead, not native SegmentCache backward-seek retention;
  seeks refill from the source and the fMP4-specific SessionCacheStatus API is
  unchanged. Native, live and forward-only playback retain their existing paths.
  Physical cache-bar/seek/pause/healthy-native acceptance is still pending.
  Run `Scripts/test-software-packet-{coverage,disk-fifo,read-ahead}.sh` and
  `Scripts/test-software-stored-packet.sh` for focused model, concurrency, disk
  failure/lifecycle and actual bundled-FFmpeg packet roundtrip checks.

- Recovery-point compatibility candidate (2026-09-07): three user-reported H.264
  MP4 assets have non-IDR I slices with immediate/exact recovery-point SEI every
  12 frames. Native tvOS output falls from about 30 to 3 fps after cached seeks,
  while target-segment DTS/duration and mux writes remain healthy. The new bounded
  VOD sample selects libavcodec only after three positively identified non-IDR
  recovery keys; ordinary IDR, absent/malformed evidence, live and non-H.264 routes
  are unchanged. This is a compatibility candidate, not yet physical acceptance.
  No bitstream/timestamp rewrite or host UI change is included. CPU cost and
  audio/video sync must be checked on the actual Apple TV. The public numeric
  `diagnostics.h264RecoveryPointKeyCount` records why this route was selected.
  `bash Scripts/test-h264-recovery-point.sh` executes the pure parser/evidence tests
  without building a host app; the matching Testing suite is retained for CI.

- Post-seek investigation (2026-09-07): source-compatible optional native-frame
  metadata now reports source/item DTS, mux duration, H.264 NAL-type mask and write
  result. This is observation only, not a cadence repair; it does not change packet
  data, flags, duration, PTS/DTS, segment cutting or transport. tvOS arm64 compilation
  passed. Initializer coverage is retained in NativeVideoFrameTimingDiagnosticTests;
  the unsupported library-scheme tvOS unit-test action is not claimed as executed.

- tvOS arm64 package compilation passed with Xcode and the frozen 3.0.0 FFmpegBuild /
  2.1.0 LibDovi dependencies (2026-09-07).
- The host's 36 focused Aether/subtitle/cache/lifecycle contracts passed.
- The SwiftPM `AetherEngine` library scheme has no tvOS test action. The attempted
  simulator test invocation did not execute tests and is not counted as a pass.
  Retained engine suites therefore still need their supported CI test runner.
- Host packaging, installed first frame and physical playback are verified separately
  against the exact pushed engine revision; a library build alone is not playback acceptance.

## Baseline

- Current upstream integration: canonical `6.71.0`,
  `f1298924bf9d53e353cd3725e06f3077e6369b8d`.
- Recovery tag: `moonfin/pre-aether-6.71.0-20260907`, resolving to
  `a66a9d3460530aafc3be2c186805cf3b69cfaa48` before the merge.
  The host repository carries the same tag at its own pre-upgrade commit.
- H.264 repair follows upstream's fractional-cadence algorithm. Moonfin adds
  structured diagnostics and its measured device regression sample, not a second algorithm.
- TLS uses upstream's owned sessions and HLS relay plus Moonfin's exact-origin set;
  the old `HLSReverseProxyServer` is retired. The host does not set the general evaluator.
- Cache budget/cleanup and dual-subtitle contracts remain; upstream residency,
  cold-seek reachability and live-cache protection must not be dropped.
- The following records the original fork lineage, not the current upstream version.

- Upstream: `https://github.com/RadicalMuffinMan/AetherEngine`
- Moonfin 2.4.0 baseline:
  `2e388e39ac4eecd7c3ad033b003f0172903ea5d3`
- Project branch: `codex/moonfin-2.4.0-tvos`
- Host repository: `https://github.com/orut34iop/media-ai-guide`

The project branch is rooted at the exact Aether revision selected by Moonfin
2.4.0. Upstream updates are assessed and merged deliberately; this branch does
not float with upstream `main`.

## Integration boundaries

- Moonfin accepts tvOS 17 as the deployment floor required by this Aether
  baseline. Host targets, tests, extensions, and generated metadata must use
  the same floor.
- The host pins only a full, pushed commit SHA from this fork. A version
  shorthand, branch name, or floating `main` is never a release dependency.
- AetherEngine is the only playback kernel in the final tvOS application.
  MPVKit, libmpv, the previous custom native playback main path, and runtime
  kernel fallback are removed at the host cutover.
- Streaming cache remains session-only. Moonfin uses Aether's disk-backed fMP4
  `SegmentCache`; a normal session close deletes its segment directory. The
  project does not implement cross-session HTTP Range-cache persistence.
  Seekable software VOD additionally retains bounded compressed packets in a
  session-owned disk store. Cache-local seeks replay retained keyframe preroll
  without moving the source reader; cache misses reset and seek the source.
  The shared buffer frontier is verified selected A/V time coverage, while
  native fMP4 `SessionCacheStatus` is still route-specific. This does not claim
  identical storage formats or cross-session retention on the two paths.
- Product UI, focus, subtitle layout, and translation providers remain in the
  host. Demux, decode, route selection, subtitle cue production, session-cache
  contracts, and other engine behavior are fixed in this fork rather than by
  untracked host workarounds.
- First-release dual subtitles cover text, ASS, and external tracks through the
  host's two-row layout and symmetric engine channel contracts. Secondary
  bitmap support remains disabled until focused engine fixtures prove decode,
  seek/reload generation, and geometry behavior end to end.
- First-release subtitle translation consumes embedded text cues that Aether
  publishes. Remote-HLS and external subtitle translation remain out of scope;
  neither the host nor this fork may silently add a Jellyfin extraction or
  temporary-sidecar path to expand eligibility.
- Moonfin does not add audio-delay support to Aether. Every Aether route is
  exposed to the host with `audioDelaySupported=false`; the existing no-op is
  not a successful capability and must never be presented as an applied value.
- Process-global `EngineTLS.allowUntrustedCertificates` is forbidden for every
  Moonfin candidate. Before the host pins an integration commit, this fork must
  expose a per-origin trust policy that matches the configured Jellyfin scheme,
  host, and effective port exactly. Redirects and sibling media, subtitle, HLS,
  or audio origins do not inherit approval.
- Moonfin inherits this baseline's decrypted DVD-Video/Blu-ray ISO playback
  only through its generic seekable local or HTTP(S) source adapter. The first
  release adds no ISO-specific engine patch, SMB product, disc browser,
  title/chapter selector UI, decryption, menu/BD-J/multi-angle behavior, server
  workaround, or failure-compatibility work; the existing default-main-title
  behavior is the accepted boundary.
- PiP, AirPlay, Live/DVR, SMB, and audio tap stay outside Moonfin's first-release
  implementation scope. This fork keeps its existing APIs, but the integration
  does not add new behavior or optional runtime dependencies for those areas.

## Change and delivery rules

1. Make every required engine change in this repository first. Do not carry an
   uncommitted engine patch only in the host repository, DerivedData, or a local
   package checkout.
2. Keep behavior changes focused and use Conventional Commit subjects.
3. Add focused engine tests for the changed contract. Public API changes also
   update `docs/api.md`, `CHANGELOG.md`, and the public-API documentation tests
   in the same commit, as required by `CONTRIBUTING.md`.
4. Push each verified engine commit promptly. The host repository then pins
   the full pushed commit SHA and records it in its task ledger.
5. Preserve the LGPL-3.0 license and Apple Store / DRM exception. Source for
   this fork, including every modification, remains public.
# Partial composition-offset follow-up — 2026-09-07

Separate from submitted PRs #510/#511/#512: a healthy MP4 head can be followed by
zero-offset IDR sequences. The partial policy restores existing timestamp-slot
ownership without moving DTS/index time or assuming constant cadence. It is
enabled only when the healthy origin corroborates the edit/index presentation
lead; unsupported sequences are not guessed. Native diagnostic publication
reports later region decisions without waiting on demux I/O.

Focused checks: `Scripts/test-h264-partial-composition-controls.sh`, existing
timestamp controls, Matroska policy and recovery recognition. Generated fixtures
contain solid colour/tone only. Packet payload, DTS, audio and metadata are
preserved; private source regressions and device evidence are recorded in the
host's `docs/testing/aether-partial-composition-investigation-20260907.md`.
Physical acceptance is pending for this new candidate. Rollback tag in both
repositories: `moonfin/pre-partial-ctts-20260907`. Do not fold this new work into
the already submitted and independently accepted PR branches.
