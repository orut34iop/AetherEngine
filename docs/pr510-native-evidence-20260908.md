# PR #510 native-route diagnostic branch

This branch is an experiment, not a production fix or a revision proposed for merging into #510.
Baseline: `c16e23dc28dafc85d5864b407230e30b51313730`; its runtime is the accepted
`b72fa6bbd2efd8de8be2a2983b50f1f746d29afa`. The original fork branch and existing
upstream PR branches remain unchanged.

The two diagnostic changes are:

- Preserve the recovery-point probe and rewind but bypass only its automatic software
  selection. The other native/software capability decisions, timestamp repairs, compressed
  cache, source transport and host UI remain the baseline behavior. The trace records
  `PR510Diagnostic native_comparison=true` with the original classifier decision.
- Save the exact initial MP4 bytes as `tmp/aether-segments/<session>/diagnostic-init.mp4`.
  Media fragments already exist there as `seg-N.m4s`. The init write is atomic, capped
  at 1 MiB, and serialized with cache close. Failure is diagnostic-only and cannot fail
  playback. No source filenames, URLs or packet payloads enter logs.

The export is for ordinary VOD with a single initialization configuration. Do not switch
audio tracks or use SSAI/multi-init playback during the capture. This branch does not
export versioned SSAI initialization data. The init write is a small synchronous action
at session initialization, not an ongoing frame/segment capture loop.

Use the tvOS application's canonical device pipeline and exact engine pin. For the first
original private source, play from the head for 30 seconds, seek to about 703 seconds,
play for 60 seconds, pause 5 seconds and resume for 30 seconds. Keep that session open
while exporting the exact init and three resident fragments around the observed landing.
Export only via the canonical `pull-tvos-device-logs.sh`; inventory is read-only. The
cache is deleted on stop, so do not rely on capturing it after leaving playback.

Pair exports by session directory, compare copied byte sizes and hashes, and preserve
the candidate/source fingerprints and numeric seek evidence. Inspect muxed offsets,
sample flags and picture counts before attributing failure to a decoder. Source metadata
is not proof of emitted fMP4 correctness. Do not upload movie bytes or private raw logs.

Focused host-side verification: `bash Scripts/test-pr510-native-segment-evidence.sh`.
This compiles only the Foundation evidence helper; it is not macOS app validation.
The tvOS pipeline and physical capture remain necessary to validate the integration.

Rollback is installation of the previously accepted immutable candidate through the
canonical pipeline, or a newly verified app pinning the original engine SHA. Do not
merge this diagnostic routing bypass into the production fork or move its branch.
