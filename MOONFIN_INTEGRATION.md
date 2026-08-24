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
