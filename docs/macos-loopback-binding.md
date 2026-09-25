# Host-controlled HTTP listener scope

Based on fixed revision `98e5e3c257d486569b3014c89e9ada5ae190cc72` (6.89.1), with no engine upgrade.

`LoadOptions(localServerLoopbackOnly: true)` restricts native media and remote-HLS subtitle/relay listeners to `127.0.0.1`. The default remains false for compatibility with hosts using LAN AirPlay. Loopback-only hosts cannot serve media to a remote AirPlay receiver. Per-session 128-bit path tokens remain mandatory for both scopes.

The setting is a load-identity field: `reloadWithOptions` refuses a scope change instead of silently widening an existing session. A new load is required.

Sandboxed macOS hosts still need `com.apple.security.network.server` even for loopback listeners. Keep App Sandbox and the client entitlement enabled; do not disable sandboxing as a workaround.

Verification: 50 focused Swift tests passed (listener scope/token checks over a real socket, LoadOptions defaults/equality/inventory, reload rejection and preservation, and remote-HLS subtitle proxy regression). The socket test inspects the kernel-reported bound address rather than inferring it from a playback URL. Consumer installed-app playback validation belongs to the host integration milestone.
