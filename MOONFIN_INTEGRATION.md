# Moonfin tvOS Integration

This public fork carries AetherEngine changes required by the Moonfin tvOS
application.

## Baseline

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
