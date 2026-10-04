---
namespace: elixirssi-monitor
version: 0.1.0
display_name: ElixirSSI status endpoint and monitor
profiles: []
sample: false
provides: []
requires: []
authoring_inputs:
  - kind: specification-to-source-skill
    uri: skills/specification-to-source/elixir-beam-system/SKILL.md
workflow_definition: workflows/production/staging/dev/workflow.md
routing_policy: routing/production/staging/dev/routing.json
flavor_slots: []
entrypoints: []
acceptance_contracts: []
source_dependencies: []
---
# ElixirSSI monitor

How an [ElixirSSI](../elixirssi/component.md) cluster is watched, and acted
on, from outside it: the status endpoint every member serves, and the
monitor page that runs in a browser and keeps working when members, or all
of them, are gone. The implementation is `os/ssi/lib/ssi/status*`,
`os/ssi/lib/ssi/web*` and `os/ssi/priv/monitor/index.html`; the rationale is
in [docs/architecture/elixirssi.md](../../docs/architecture/elixirssi.md),
"Watching the system from outside".

## Status endpoint and monitor

The cluster is observed from outside it, so the observer keeps working when
members, or all of them, are gone.

- Every member serves a read-only status endpoint over HTTP on `web.port`
  (default 80; `0` disables it), on all of its addresses:
  - `GET /` returns the monitor page;
  - `GET /api/status` returns a JSON snapshot (schema `elixirssi-status/1`);
  - `GET /api/stream` upgrades to a WebSocket that sends a snapshot with the
    journal at once, then a snapshot without it every second, and each
    journal event as it is recorded.
  Responses allow any origin, including a page opened from a local file
  (`Access-Control-Allow-Origin: *`, and `Access-Control-Allow-Private-Network`
  on preflight). Reading needs no credentials; the only requests that change
  system state are the signed control messages below, and methods other than
  `GET` and `OPTIONS` are refused.
- A snapshot is built from the member's own memory, without calls to other
  members. It holds the observer (node, hostname, boot id); the system as one
  machine (members, cores, schedulers, memory, mean scheduler utilisation,
  processes); each member (hardware, addresses and web port, uptime, latest
  load sample and utilisation history, the services it runs, and how its
  previous boot ended); every registered service with where it runs, where it
  should run, and whether it is running; and the member's recent journal.
- Each member keeps a journal of its last 200 events. It records members
  joining and leaving as it observes them, and receives the service and boot
  events every member originates: a service starting (and, when it replaced
  an instance on a member that is no longer a member, the time since that
  member was last heard from), a service stopping, and a member booting with
  its previous-boot record. Event ids are unique across the cluster.
- A member with a persistent data partition records each boot there and
  refreshes it every 30 seconds while running. Restart and power-off mark the
  record as ended cleanly with the requested action before reboot(2). At the
  next boot the member reports its previous boot as ended `clean` (with the
  action), `unclean` (power loss, kernel panic or BEAM failure, with the last
  time it was known alive), or `unknown` (no persistent record).
- The monitor is one self-contained HTML file with no external resources. It
  runs from a local file, or is served by any member (and can be saved from
  there). Its endpoints come from its own origin when a member serves it, the
  URL fragment `#endpoints=HOST:PORT,...`, and the user, and persist in the
  browser.
- The monitor holds a WebSocket to every endpoint at once and reconnects to
  each with backoff (at most five seconds). An endpoint that fails within one
  second is reported as refusing connections (reachable, nothing serving:
  booting or stopped); one that fails later as a failed connection (browsers
  delay repeated attempts to a failing host, so the two blur); one that does
  not complete within four seconds, or a live one silent for five, as not
  responding (off, disconnected or unreachable from this browser).
- The monitor remembers in the browser every member it has seen (by host
  name, matched by node name), its last snapshot, and up to 500 timeline
  events, and shows them after a reload even
  when nothing answers. A member can be forgotten by the user.
- It shows one verdict with its reasons:
  - **Down** — no endpoint answers; since when, and how each fails;
  - **Split** — two answering members have reported different memberships for
    more than 10 seconds, not counting a member that booted less than a
    minute ago and sees only itself (it is joining); the groups;
  - **Degraded** — a remembered member is in no answering member's
    membership, or a registered service is not running; which and since when;
  - **Healthy** — otherwise.
- It shows the system view (the aggregate machine, utilisation history, the
  services and where they run), the member view (one card per remembered
  member, with its state, last sample, services and previous-boot record),
  the timeline (events merged by id from every endpoint, newest first, with
  one entry per membership change however many members observed it, and the
  monitor's own verdict and endpoint changes, which are all it can know once
  nothing answers), and the endpoints with their connection state.

## Monitor controls and TLS

Reaching the endpoint is enough to read the cluster's status, never to change
it. Changing it takes a key the cluster has been told to trust.

- A browser holds one ECDSA P-256 key pair, generated in the browser and
  stored non-extractable (WebCrypto in IndexedDB), so the private key cannot
  be copied out of the page. Its key id is the first 16 characters of the
  unpadded base64url SHA-256 of the raw public key.
- A key is trusted once it is *paired*. In a shell (console or SSH, so an
  operator who can already log in), `monitor_pair(name)` issues a one-time
  pairing code of 80 random bits, valid for 10 minutes on every member. The
  monitor sends its public key with an HMAC-SHA256 of the request, keyed by
  the code, over the connection's challenge; a member that finds a matching
  unexpired code consumes it and records the key under `name` in the
  replicated store. The code itself never crosses the network.
  `monitor_keys()` lists trusted keys and `monitor_revoke(id_or_name)` removes
  one; both take effect on every member.
- Each WebSocket connection starts with a `hello` carrying a fresh 32-byte
  challenge. A control request is a JSON text that names the key, a sequence
  number and the action; the monitor signs the challenge and the exact
  request text with its key. A member performs the action only if the key is
  trusted, the signature verifies over that connection's challenge, and the
  sequence number is higher than any already used on the connection, so a
  request cannot be forged, altered, or replayed on this or another
  connection. Every request gets a `result` reply. Each authenticated request
  is journalled as a `control` event (action, target, key name, outcome)
  sent to every member; refused unauthenticated requests are not, so they
  cannot push real history out of the journal.
- Actions: `migrate` a service to a member; `restart` or `poweroff` a member
  (the same orderly path as the shell's `reboot`/`poweroff`, so the member's
  previous boot is reported as ended cleanly with that action). A member that
  cannot carry out an action (for example a hosted node asked to power off)
  replies with an error.
- Snapshots list the trusted key ids (not their names) under `control`, so
  the monitor knows whether it is paired and sees a revocation at once.
- Signed requests are accepted over HTTP as well as HTTPS: the signature
  provides authentication and integrity, and actions are not secret. TLS adds
  confidentiality and lets the browser know it is talking to the cluster.
- Every member also serves the endpoint over TLS on `web.tls_port` (default
  443; `0` disables it). Its certificate is issued at boot, and again when the
  member's addresses change, by a *web CA* whose ECDSA P-256 key is derived
  from the cluster secret, so it is the same on every member and survives any
  restart without being stored. The certificate names the member's host name,
  `localhost` and each of its addresses including loopback (so port forwards
  and SSH tunnels verify), is valid from 2026 to 2126 (members may boot
  without a clock), and is sent without the CA certificate, so a browser
  builds the chain from the CA it was told to trust. The member's own key is
  derived from the secret and its host name, so it is the same at every boot
  and may be pinned; TLS 1.3 key exchange is ephemeral, so this costs no
  forward secrecy. `GET /ca.pem` returns the
  web CA certificate; `monitor_ca()` in a shell prints its SHA-256 public-key
  fingerprint, against which an operator checks a downloaded copy before
  trusting it. (The distribution CA uses Ed25519, which browsers do not
  accept in certificates; hence a separate CA.)
- WebCrypto exists only in secure contexts, so the monitor offers controls
  when it runs from a local file or from `https://`; served over plain HTTP
  it is read-only. Endpoints may be given as `HOST:PORT` (WebSocket) or
  `https://HOST:PORT` (secure WebSocket); a monitor served over HTTPS uses
  secure WebSockets.
- The monitor shows whether this browser is paired, offers pairing with a
  code, offers restart and power off on each answering member and a move to
  another member on each service, asks for confirmation in the page before
  restart or power off, sends each request to the member it concerns when
  that member answers (else to any answering member), and shows the result.

## Acceptance

| Scenario | Evidence |
| --- | --- |
| Status snapshot, journal, previous-boot record, HTTP and WebSocket endpoint | `make test` (`status_test.exs`, `web_test.exs`) |
| The monitor, in a browser, across four emulated CM5s: healthy; a power pull (degraded, failover time, unclean previous boot); a partition (split) and its heal; the whole cluster down (last known state kept across a reload); recovery | `make test-monitor` |
| The same monitor scenarios on four `virt` nodes | `make test-monitor BOARD=virt` |
| Pairing, signed controls (refusal of unsigned, forged, replayed and revoked requests), web CA and certificates over TLS | `make test` (`control_test.exs`) |
| Monitor controls in a browser over TLS on four emulated CM5s: an unpaired request refused, pairing, move a service, restart and power off a member, revocation | `make test-monitor` |
