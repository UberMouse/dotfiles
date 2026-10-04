---
name: home-assistant
description: Use when operating, diagnosing or changing taylorl's Home Assistant instance (devices, integrations, automations, Node-RED flows, apps/add-ons, config YAML) through the home-assistant MCP server or hass-cli
---

# Home Assistant

How to reach and safely change the house's Home Assistant from this machine,
plus the traps that cost real time the first time round (2026-10-02). Live
facts — HA/OS versions, entity counts, what is broken right now — are NOT
recorded here; read them from the instance (`ha_get_overview`), they rot.

## Access

- The instance is HA OS in a VM on the home LAN. This machine is NOT on that
  LAN: everything goes through the Nabu Casa remote URL. Nabu Casa tunnels
  only the web UI and API, so there is no SSH path and no direct LAN access.
- Two tools, both op-cached wrappers declared in `scriptBins/default.nix`
  (`opTools.hass-cli`, `opTools.ha-mcp`):
  - **`home-assistant` MCP server** (ha-mcp) — the main tool. A uvx launcher
    pinned in `packages/ha-mcp/package.nix`; `/weekly-update` bumps it.
    Registered PROJECT-scope in the tracked `.mcp.json` (pre-approved by
    `enabledMcpjsonServers` in the tracked project settings), so it starts
    only in sessions rooted in this repo or its worktrees. It was user-scope
    once, and every session in every repo spawned it and prompted for the
    1Password unlock; don't move it back.
  - **`hass-cli`** — raw REST fallback for anything no MCP tool covers:
    `hass-cli raw get /api/...`, `hass-cli raw post /api/... --json '{...}'`.
- Both read the same 1Password item (personal account, `Private` vault, item
  `home-assistant`: `credential` = an admin long-lived token, `hostname` = the
  Nabu Casa URL) under ONE shared caller, `home-assistant`. A cold cache costs
  two prompts (one per field); then nothing for 15 idle minutes, for either
  tool. The URL lives in 1Password, not the repo, because the repo is public.
- A wrapper change needs a switch AND `/mcp` → reconnect `home-assistant`:
  the running server keeps the environment it started with. A session that
  started before the server was registered cannot see its tools at all.

## Working with ha-mcp

- **Best-practices gate.** Write tools (`ha_config_set_automation`,
  `_helper`, `_yaml`, …) demand a `BestPracticeKey`. It is printed at the top
  of any `ha_get_skill_guide` reference file and rotates hourly — on
  `BPS_ACKNOWLEDGMENT_REQUIRED`, re-read a reference for the current key. Read
  the server's own guidance for real, not just for the key: its
  safe-refactoring reference before any rename or removal, its backups
  reference before anything irreversible.
- **YAML is narrow.** `ha_config_set_yaml` writes only an allowlist of
  YAML-only integration keys (template, rest, command_line, sensor, mqtt, …).
  Any other top-level key is a hand edit for the user (Studio Code Server
  app). Reading is broad: `ha_config_get_yaml` / `ha_read_file`. Both need
  the companion "HA-MCP File & YAML Tools" component (HACS:
  homeassistant-ai/ha-mcp-integration, domain `ha_mcp_tools`) plus the beta
  flags in the wrapper. The component is pinned to the last release that
  supports the installed HA core — move it when HA core is upgraded.
- **`partial: true` means not exhaustive.** Config-body searches drop items on
  Nabu Casa TLS hiccups and per-item timeouts. Re-run narrower (one query, no
  `include_config`) before concluding something is unreferenced.
- **Long operations time out client-side but keep running server-side**
  (Matter commissioning, add-on updates). Read the app's log
  (`ha_get_logs(source="supervisor", slug=...)`) before retrying.
- **Supervisor API**: `ha_call_service(ws_command="supervisor/api",
  data={"endpoint": "/network/info", "method": "get"})`.
- **Repairs**: `ha_manage_updates` can only *ignore* one. The real fix flow
  is `hass-cli raw post /api/repairs/issues/fix --json
  '{"handler":"<domain>","issue_id":"<id>"}'`, then POST `{}` to
  `/api/repairs/issues/fix/<flow_id>`.
- **App (add-on) APIs** go through `ha_manage_app(slug=..., path=...)`:
  - Node-RED — `path="/flows"` returns every node. `python_transform` allows
    no imports; filter with `str(n)` substring tests. Edit one node with
    `array_patch={"operations": [{"op": "patch", "id": "<node id>",
    "patches": {"<field>": <value>}}]}` and
    `request_headers={"Node-RED-Deployment-Type": "nodes"}`, then read the
    node back.
  - Matter Server — `path="/ws", websocket=True, wait_for_close=True`;
    commands `discover`, `commission_with_code` (`code`, `network_only`),
    `commission_on_network` (`setup_pin_code`, `ip_addr`).
  - Filebrowser has its own login (401 through the proxy) — don't.

## Entity consumers live in TWO places

HA's automations/scripts/helpers/dashboards AND the Node-RED app's flows —
real automations live in Node-RED (the washing-machine-finished
announcement, for one), and HA's own search cannot see them. Before renaming
or removing an entity, search both.

When a device moves to a new integration, prefer **reusing the old entity
IDs** over repointing consumers: copy area/name/voice exposure off the old
entities, delete the dead config entry (frees the IDs), rename the new
entities onto them. Every consumer keeps working untouched, and recorder
history and long-term statistics continue when unit and `state_class` match.
Check that before renaming.

## Device traps

- **The Tapo hub (H100), its sensors and the washing-machine plug run over
  Matter, not the `tplink` integration.** Tapo firmware moved them to TPAP
  encryption, which HA's bundled python-kasa cannot speak (upstream: the open
  python-kasa TPAP PR, python-kasa/python-kasa#1592). The signature:
  `403 to handshake1` on connect, or every query returning `-100001`. Don't
  re-add `tplink` for these until a python-kasa release ships TPAP and HA
  bundles it. A Third-Party Compatibility toggle fixes the same 403 on some
  OTHER Tapo models, which is a red herring for these.
- **Pairing a Tapo device to Matter** needs the Tapo app's device → Device
  Settings → "Bind to Matter (Beta)" screen, which opens a timed window
  (a countdown shows). The code looks static, but outside that window the
  device neither advertises nor answers — `discover` comes back empty.
- **Matter needs IPv6 enabled on HA OS's interface** (Settings → System →
  Network). The router hands out no global IPv6; link-local is enough.
- **The Matter bridge drops things:** battery levels, signal, buttons
  (S200B), the hub's siren and settings. They do not exist over Matter.

## Updating HA OS / Supervisor / Core

- **"No updates available" can mean the Supervisor has stopped looking.**
  Once HA OS falls more than ~4 majors behind the newest release, the
  Supervisor marks the system `unsupported: os_version` and its job gate
  blocks `Updater.fetch_data`, the store reload AND its own self-update. Core,
  Supervisor and every app then report `version_latest == version` forever.
  Signature in the Supervisor log (`ha_get_logs(source="system_service",
  slug="supervisor")`): `'Updater.fetch_data' blocked from execution,
  unsupported OS version`. Check `/resolution/info` before believing any
  "up to date". Ran 13 months like this (Core 2025.8.3 → found 2026-10-02).
- **Way out: step the OS by explicit version.** `/os/update` itself is NOT
  gated on OS support (only HEALTHY + SUPERVISOR_UPDATED against the cached
  data), and it takes a version:
  `ha_call_service(ws_command="supervisor/api", data={"endpoint":
  "/os/update", "method": "post", "data": {"version": "X"}})`. The cached
  upgrade target won't advance on its own (it is computed only at fetch
  time), so pass every hop. The hops come from the `hassos-upgrade` map in
  https://version.home-assistant.io/stable.json: stay on the map's entry for
  your current major, then jump to the next major's entry. Once within range,
  the Supervisor fetches, self-updates, and normal update entities reappear.
- **Wait for the Supervisor's own `running` state** (`/info` → `state`)
  between hops. Core reporting RUNNING is not enough: an `/os/update` sent
  while the Supervisor is still in `startup` is refused.
- **Supervisor ≥2026.07 no longer reboots after `/os/update`.** It raises a
  `reboot_required` issue instead. Send `POST /host/reboot` yourself.
- **This VirtualBox VM can hang at shutdown on an OS-update reboot.** The
  RAUC install has already committed by then, so a hard power-off at the
  host is safe and boots the new slot. Nothing here can reach the host, so
  the user has to do it. Tell them before each reboot.
- **Upgrade Core before running old Core on a much newer OS.** The VirtualBox
  Core segfault on OS 18.0 (operating-system#4828) needed both OS 18.2+ and
  Core 2026.7.4+.
- **`ha_manage_backup(scope="snapshot", action="create")` refuses when HA has
  no default backup password.** The existing backups are unencrypted (Google
  Drive Backup app). Create one through the Supervisor instead:
  `{"endpoint": "/backups/new/full", "method": "post", "data": {"name": ...}}`,
  then poll `/jobs/<job_id>`.
- **Google Drive Backup's retention counts by NUMBER, in HA and in Drive
  alike, and it evicts full backups for tiny ones.** Read its
  `max_backups_in_ha` / `max_backups_in_google_drive` options
  (`ha_get_app(slug="cebe7a76_hassio_google_drive_backup")`) before creating
  any backup. On 2026-10-02, six app updates run with `backup: true` produced
  six partial backups, and retention deleted EVERY full backup from both
  places, including the pre-upgrade one. `ignore_upgrade_backups: true` is
  now set, so HA's automatic pre-update backups no longer count. Ad-hoc
  backups made through the Supervisor still do. Check what survived with
  `ha_manage_app(slug=..., path="/getstatus")`.
- **Custom components break on Core jumps, and some must move BEFORE Core.**
  HACS only offers releases whose minimum HA version is met, so a component
  whose installed release breaks on the new Core may need a "bridge"
  release on the old Core (`ha_manage_hacs(action="download",
  version=...)`), and its newest release afterwards. Check each component's
  imports against the target Core before moving Core.

## Safety

- Claude Code's auto-mode classifier blocks destructive HA operations —
  config-entry deletion, app uninstall, host network changes, activating
  newly installed custom code — even after a general go-ahead. Never route
  around it; ask for explicit permission that names the action, then retry.
- Before a restart: `ha_get_system_health(include="config_check")`, and
  confirm with the user — a restart interrupts every automation.
- Back up before irreversible operations (integration removal, core/OS
  upgrades), per the server's backups reference.
