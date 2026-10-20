# Decaid Skale plugin

This repository packages the opt-in Skale BLE scale driver for Decaid's
runtime-v2 plugin API. The host bundle contains `manifest.json` and
root-level `plugin.js`. Use the ZIP produced by `npm run package` for
installation.

## Skale name-discovery test

This test branch is based on upstream v0.2.0 and changes only the runtime
manifest's BLE discovery matcher. It matches names beginning with `Skale`
(case-insensitive), including when service UUIDs are unavailable in advertising.
The unchanged driver still requires the Skale service after connecting.

Install through Decaid **Plugins -> + -> GitHub Branch**:

```text
Repository: pponce/decaid-skale-plugin
Branch:     test/skale-name-discovery
```

The plugin keeps id `skale.reaplugin` and version `0.2.0` for this isolated
test. After reconnecting, `GET /api/v1/devices` should show the scale id beginning
with `plugin:skale.reaplugin:skale:`. Then test weight readings, on-screen tare,
and the physical circle-button tare. Hardware success remains to be confirmed.

## Installation

This plugin requires a Decaid build containing the runtime-v2 plugin contract:
BLE `bindDriver`, four-binding admission, session `publishInfo`, validated
driver `surfaces`, and `pluginStorage`. The contract was present on Decaid
main at `af4e99524ad7731dbdb7db4540cd272bc91da038` (2026-10-10). The stable
`0.8.8` release predates the final settings-surface and Scale metadata pieces;
use a newer host build and check its plugin documentation before installing.

Decaid can install this repository directly from its GitHub branch installer:

```text
Repository: MaxRink/decaid-skale-plugin
Branch:     main
```

That installer downloads the branch archive, finds the single directory that
contains `manifest.json` and `plugin.js`, validates the manifest, and records
the resolved commit as the plugin source. For stable installs, select the latest
[GitHub release](https://github.com/MaxRink/decaid-skale-plugin/releases), whose
single ZIP matches the manifest version. A local build can use
`dist/decaid-skale-plugin-<version>.zip` through the local ZIP installer. The ZIP
has the required runtime files and licence notices at its root.

The plugin id is `skale.reaplugin`. After installation, enable it in Decaid's
plugin management UI and grant the requested BLE, API, and plugin-storage
permissions. The settings action is provided by the declared `settings`
surface; its `deviceId` and optional display name are supplied by Decaid's
device-management authority.

The plugin supports the current host contract:

- host-owned BLE with up to four independently fenced bindings;
- one primary brewing scale and runtime-only auxiliary scales, with no driver
  role assignment or persisted dosing role;
- 4-byte fixed point and 5/9-byte signed mantissa/exponent weight frames;
- nullable firmware and battery publication through `context.publishInfo`;
- tare, timer and display commands;
- a validated `role: "settings"` surface backed by the namespaced
  `pluginStorage` KV store.

USB power is a manual, default-off declaration. It suppresses battery reads and
publishes `batteryLevel: null`; it is not sensed power. The Skale circle button
notification (`ef82`, payload `0x01`) performs a local scale tare and is fenced to
that BLE session. Square (`0x02`) and unknown or malformed button payloads are
ignored. Square machine actions remain subject to the held host action review
(#845/#853). Button command write failures propagate through the host BLE session;
missing button subscription is tolerated so weight remains usable.

## Development

```sh
npm test
npm run package
```

Browser contract checks use a fake GATT session and Playwright Chromium; they do
not require a physical scale:

```bash
npm ci
npx playwright install --with-deps chromium
npm run test:browser
```

The browser suite covers the settings page, persisted USB-power reload,
malformed settings rejection, weight publication, tare, and circle-button tare.
CI runs it on Node 24 alongside the native Node matrix.

GitHub Actions runs the protocol/session suite and package-root checks on Node
22 and 24 LTS plus Node 26 Current. A focused host-contract job runs Decaid's
real package resolver and manifest parser against both a GitHub-style source
archive and the generated local ZIP, then runs `ci/host_runtime_test.dart` inside
the pinned host QuickJS runtime with fake GATT transports. It covers multi-binding
isolation, settings/pluginStorage persistence, nullable metadata, commands, circle
tare, ignored square/unknown buttons, write failures, and late-event fencing.
The host is pinned to revision `af4e99524ad7731dbdb7db4540cd272bc91da038`.

The package is a ZIP containing only the manifest, plugin source, README and
GPL-3.0 license. The generated ZIP is not a release or a hardware-validation
claim.

## Provenance and license

The protocol implementation and focused fixture behavior were ported from the
closed Decaid PRs #846 (`feature/skale-plugin-review`) and #859
(`feature/skale-multiple-scales`), authored by Maximilian Rink. The source was
reworked to use the accepted current `surfaces` contract and retains the
original copyright and contribution history in `NOTICE`. The Decaid host is
GPL-3.0-or-later; this plugin is distributed under the same license.

The source references were inspected at Decaid main `af4e99524ad7731dbdb7db4540cd272bc91da038`
and PR #859 head `4816cf02a42b6c9b0f2aea897054044afb8d360e` on 2026-10-10.

## Limitations

No physical hardware run is included. Host platform trust and plugin transport
permissions still apply. Self-signed TLS is unrelated to this BLE plugin and
must be solved in the host/E64 plugin separately.

## Releases

Install the latest [GitHub release](https://github.com/MaxRink/decaid-skale-plugin/releases)
through Decaid’s plugin installer. Each release has exactly one flat ZIP with the
manifest, runtime plugin and licence notices. The tag must match the manifest
version. Subsequent releases require a version bump in the manifest, package and
lockfile.

The tag-triggered release workflow reruns the complete repository CI and publishes
the tested archive only after all jobs pass. `npm run package` produces a
deterministic archive under `dist/`; documentation, mocks and CI fixtures remain
in the repository. CI proves synthetic software behavior, not physical hardware
or firmware compatibility.
