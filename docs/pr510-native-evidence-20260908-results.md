# PR #510: Apple TV native-route reproduction evidence

Recorded September 8, 2026. All clock times below are UTC+8 unless explicitly marked.
This is a diagnostic result, not a replacement fix or a request to merge the existing
software-routing predicate unchanged. Private sources are identified only as A/B/C.
No movie bytes, source filenames/URLs, raw device logs or device identifiers are published.

## Scope and provenance

- Discussion: [PR #510](https://github.com/superuser404notfound/AetherEngine/pull/510),
  following the [maintainer review](https://github.com/superuser404notfound/AetherEngine/pull/510#issuecomment-5572848774).
- Accepted downstream runtime: `b72fa6bbd2efd8de8be2a2983b50f1f746d29afa`;
  diagnostic branch baseline `c16e23dc28dafc85d5864b407230e30b51313730` has the same runtime.
- Installed diagnostic engine:
  [cd3e80d37605c3d6280c0331015d41aa8c6f4405](https://github.com/orut34iop/AetherEngine/commit/cd3e80d37605c3d6280c0331015d41aa8c6f4405).
- App source: `419ccfdf868263f5cd5a186a9784126bd336f14e`; build `20260908012500`.
  First frame at 01:28:41.615. Package, install, first-frame, crash and process gates
  passed on the same physical Apple TV used for the original report.
- Candidate source fingerprint:
  `e830fd24ca89d3ecd1f0527131e44b0e935d114e5cc2ebb4ed3311550fc87726`.
- Candidate bundle fingerprint:
  `5d321bdaba8fca63c55e4ff30939c97ff79a78bbdff3be02fe493a2328b44e12`.

The recovery probe and rewind remain, but only their automatic software-selection
decision is bypassed. Other capability routing, timestamp repairs (including the
partial-composition implementation), software cache, host UI and seek handling are
unchanged. The second diagnostic change saves the exact initialization bytes alongside
the existing media cache: atomic, capped at 1 MiB, serialized with cache close, and
failure cannot fail playback. It does not add per-frame or per-segment capture writes.
This capture used ordinary VOD with one initialization configuration.

The focused Foundation init-capture, recovery-parser and host cadence checks passed.
A consolidated read-only implementation review found no blocking issue. Neither the
original PR head nor production app/engine branches were modified. The published
record is a documentation-only follow-up to the installed diagnostic commit above.

## Physical procedure and observed result

Requested procedure for original affected source A: play from the head for 30 seconds;
seek to about 703 seconds; play for 60 seconds; pause about 5 seconds and resume for
30 seconds; keep that session alive for export. The user reported visible judder.

Actual logged operations include an intermediate seek to 440.796 seconds, followed
by the principal target/landing at 704.807 seconds. One load began at 01:33:21.
All active samples used the native backend and the original probe reported three
recovery-point keys.

| Phase | Observation window | Active samples | AVPlayer track fps: min / median / max |
| --- | --- | ---: | --- |
| From head | 01:33:27–01:33:59 | 17 | 29.616 / 30.271 / 31.175 |
| First seek, 440.796 s | 01:34:01 | 1 | 3.098 / 3.098 / 3.098 |
| Second seek, 704.807 s | 01:34:07–01:36:07 | 56 | 2.463 / 2.862 / 3.000 |

The second window spans two minutes and excludes paused/waiting samples. During
active samples the AVPlayer loaded range stayed 4.049–6.955 seconds ahead,
`buffer_empty=false`, `likely_keep_up=true`, rate was 1 and presentation-axis shift
was 0. Access-log stall and dropped-frame counters remained zero; those counters do
not establish smooth output. This rate is `AVPlayerItemTrack.currentVideoFrameRate`,
not software enqueue rate or an optical count of unique displayed pictures.

Pause samples at 01:35:23–01:35:29 held item time at 781.116876 seconds. At 01:35:31
the player was waiting after resume; at 01:35:33 it was playing at about 2.812 fps.
Thus pause/resume did not restore the rate. The sampled pause is not asserted to be
exactly five seconds. The user independently confirmed visible judder.

## Exact native cache and source comparison

The exact initialization and eight fragments (0, 1, 109, 110, 111, 175, 176, 177)
were exported through the app's canonical exporter before the same session closed.
Inventory, byte counts, hashes and transport manifests were retained privately.
Both target groups were already resident before the respective seeks; recorded mux
epoch remained 1. These are actual cache bytes, not just pre-mux timing callbacks.

| Evidence | Bytes | SHA-256 |
| --- | ---: | --- |
| Initialization | 1,251 | `b98adb8bd50ccee058fa0a87313316a5689985e108a475c4c9e24a7e0f189646` |
| Native log | 36,877,343 | `cd04ece5b29f15996f56b1470e41656cf5646a04055ebe2fd9bc06a7e100a629` |
| Target fragment 176 | 1,838,552 | `d17685334a8c22ed7199d826dab2e354233ab4daf2c9cbb6ddc66fb22d6ef09c` |

All seven inspected noninitial fragments contain 120 video packets at time base
1/30000 with duration 1001 ticks. Their actual fMP4 PTS-DTS histogram is 0:40,
2002:40, 4004:40. Adjacent captured target DTS is continuous. The emitted samples
therefore do not have the proposed all-zero composition-offset signature.

For fragment 176, all 120 encoded packet SHA-256 values matched unique packets in
a bounded interval of original source A. Each emitted PTS and DTS is exactly +2002
ticks relative to its matched source packet; all durations match. This establishes
source identity and packet/timestamp ownership in this fragment. It does not prove
that the original picture-order metadata or Apple decoder output is correct.

A bounded box parser, self-checked on default flags, first-sample overrides, signed
offsets and malformed sizes, independently confirms the composition fields. Video
fragments 1, 110 and 176 each contain ten samples flagged `0x02000000` and 110 flagged
`0x01010000`. Their `traf` children are `tfhd/tfdt/trun`, with no `sdtp/sgpd/sbgp`
there. These are raw observations, not a claim that missing sample groups cause the bug.

Numerical FFmpeg 8.1.2 checks on exact initialization/fragment pairs:

| Input | Video packets | Software-decoded frames |
| --- | ---: | ---: |
| Initial fragment 0 | 130 | 130 |
| Continuous 0+1 | 250 | 250 |
| Each inspected noninitial fragment in isolation | 120 | 118 |
| Continuous 175+176+177 | 360 | 358 |

For the continuous target group, the absent two timestamps precede the first output
I-picture; this is not a fresh loss of two frames at each fragment boundary. Decoded
PTS is strictly increasing. All probe/decode processes returned zero, with no counted
MMCO, missing-reference, slice-header, decoding or nonmonotonic warnings. Unavailable
decode-error flags are not treated as zeros. These are software observations only;
they do not answer whether Apple's decoder independently decodes these fragments.

The old generated open-GOP analyzer control still returns 360/360 frames and strictly
increasing decoded PTS. It has not been a fresh negative routing control on this
Apple TV candidate; that physical control remains outstanding.

## Original-source measurements and acceptance chronology

All three original sources were freshly sampled with ffprobe 8.1.2. Each 300-packet
sample at requested time 696 seconds contains 0, 2002 and 4004 tick PTS-DTS offsets,
100 each, at time base 1/30000. The head samples also contain genuine nonzero offsets.
A separate 12-second sample near 703 seconds has 360 packets and zero IDRs for each
source, with 30/30/31 immediate/exact recovery SEIs. Container-key offsets are 4004
ticks, except for one 2002-tick key in source C. This is not the zero-offset IDR start
required by the current partial-composition repair. These remain bounded observations.

The original three-source software acceptance predates the other three fixes:

- Compatibility implementation `99f8c23c74884ec7d62810df9c6b9be31939f484` was committed
  September 7 at 11:59:59; candidate `20260907120107` first framed at 12:03:56. Retained
  playback logs and the subsequent user confirmation record the three-source result.
- Software-cache, Matroska and partial-composition changes came later. The latter,
  `0f807178c2812f2354a8abbfe8326a0004115301`, was committed September 7 at 16:43:38.
- That initial acceptance was therefore not an all-four-patches test. The isolated
  upstream PR branch was not separately installed, as its PR description states.

## Conclusions and remaining tests

1. The native route still exhibits user-visible judder with the other accepted repairs
   present. The actual target fragment preserves the source's encoded packets and
   nonzero-offset pattern, so the proposed all-zero-offset explanation is not supported
   for this captured interval.
2. This does not establish a native decoder defect or justify automatic software
   routing for every recovery-point stream. The maintainer's healthy open-GOP
   counterexample remains valid evidence against the broad routing predicate.
3. Only the native half of this new diagnostic comparison was run. The earlier
   accepted software playback is historical evidence, not a fresh same-build paired A/B.
4. The next discriminator is native tvOS decoding of these exact init/fragments in
   isolation from the current AVPlayer/HLS seek session, with a generated healthy
   open-GOP control. Preserve native decoded timestamps and status numerically before
   assigning the failure to decoder random-access state, container metadata or session
   handling. This test and a narrower replacement fix remain uncompleted.

No native replacement fix, upstream adoption or smooth-output acceptance is claimed.
Do not merge the diagnostic routing bypass as a production repair.
