# Image contract — `ghcr.io/dirkwa/svxlink-server`

This file is the **single source of truth** for everything
`svxlink-universal-installer` assumes about the images this repo publishes.
The installer's `check-image-contract.sh --remote` fetches this file and
`entrypoint.sh` raw from this repo and greps its quadlet template against
them. **Change nothing here without a matching installer release.**

## Image name and tags

| Item | Value |
|---|---|
| Image | `ghcr.io/dirkwa/svxlink-server` |
| `:latest` | newest upstream **release** of sm0svx/svxlink (mutable) |
| `:<YY.MM.N>` / `:<YY.MM>` | exact release / newest patch of a series |
| `:master`, `:master-<sha7>` | upstream master snapshot (≤3 h lag) |
| `:git-<sha7>` | manual dispatch builds |
| Architectures | linux/amd64 + linux/arm64 (one manifest list) |

## Process model

- `ENTRYPOINT /entrypoint.sh`, `CMD ["svxlink"]`. One supervised process per
  container; CMD selects `svxlink` | `remotetrx` | `svxreflector`; any other
  CMD is exec'd verbatim (debug shell).
- **No `START_*` environment variables** (deliberate break with
  f4hlv/svxlink-docker). Process choice is the quadlet's `Exec=`/CMD.
- The container runs as **root-in-userns**: no `USER` directive, no baked
  uid-1000 account contract. Under rootless podman container-root == the
  invoking host user, so `~/.svxlink/{etc,log}` bind mounts need no chown;
  device access is the quadlet's job via `GroupAdd=keep-groups` (never
  `UserNS=keep-id` — podman#28364). Files the container creates on bind
  mounts appear host-user-owned, mode 0644 (umask 022) — the dashboard's
  read path depends on that.

## Environment contract (entrypoint)

| Env | Default | Meaning |
|---|---|---|
| `SVXLINK_CONF` | `/etc/svxlink/<prog>.conf` | main config path. **Unset in the image ENV** so each CMD gets its own default; the installer's quadlet sets it explicitly for the svxlink node. Entrypoint exits 1 with a clear message if unreadable. |
| `SVXLINK_LOGFILE` | *(empty)* | empty ⇒ stdout-only: svxlink is exec'd with **no** `--logfile` flag at all (its logfile writer mishandles `/dev/stdout` when that is a pipe — every line vanishes, verified 2026-07-30; bare stdout streams fine, journald stamps times). Set (installer: `/var/log/svxlink/svxlink`) ⇒ svxlink writes that file, the entrypoint mirrors it to stdout (`tail -n0 -F`, started before svxlink to minimize the attach race) and rotates it. |
| `SVXLINK_LOG_MAXSIZE` | `10485760` | size-only rotation threshold in bytes: `mv → ${SVXLINK_LOGFILE}.1` + `SIGHUP` (svxlink reopens its logfile). Exactly **one** `.1` sibling ever exists — the CN8VX dashboard reads `LOGFILE` and `LOGFILE.1`, nothing older. No calendar rotation. |
| `LC_ALL` | `C` (baked) | the dashboard's date regexes require C-locale month-name timestamps. The image installs **no** `locales` package; do not add one. |

Shutdown: entrypoint forwards TERM/INT to svxlink and waits; the hard stop
bound is the quadlet's `TimeoutStopSec` (systemd SIGKILLs the cgroup), not
the entrypoint.

## Filesystem contract

| Path | Guarantee |
|---|---|
| `/etc/svxlink/` | pristine upstream config tree present in the image (deb conffiles: `svxlink.conf`, `svxlink.d/` with the `Module*.conf` set, `remotetrx.conf`, `svxreflector.conf`, `gpio.conf`, `node_info.json`, `TclVoiceMail.conf`, `ca-hook.yaml`). The installer seeds `~/.svxlink/etc` from here via `podman create` + `podman cp` (the full tree — `remotetrx.conf`/`svxreflector.conf` back the entrypoint's per-prog defaults), then bind-mounts over it. |
| `/usr/share/svxlink/sounds/en_US` | baked, pinned voice pack (see `org.svxlink.image.sounds` label). Language override = mount a host dir at `/usr/share/svxlink/sounds/<LANG>` (`:ro`). **Never** mount `/usr/share/svxlink` or `.../sounds` wholesale — it hides `events.d/*.tcl` and the baked pack. |
| `/var/log/svxlink`, `/var/lib/svxlink` | exist; the installer bind-mounts its log dir over the former. `WORKDIR /var/lib/svxlink`. |
| Diagnostics in image | `pgrep` (procps), `aplay`/`arecord` (alsa-utils). |

## Ports

`EXPOSE 5198/udp 5199/udp` (EchoLink inbound). 5200/tcp is **outbound** to
the EchoLink directory — publishing it is a no-op, deliberately not exposed.
Documentation only: the installer runs `Network=host` (EchoLink registers
the observed UDP source address; NAT breaks it).

## Health

**No baked `HEALTHCHECK`** — under Quadlet it spawns transient timers with
no consumer. `svx health` probes from the host (`systemctl` + in-container
`pgrep -x svxlink` + log-file growth after restarts). Log *freshness* is
never a failure signal: idle repeaters legitimately log nothing for hours.

## OCI labels

| Label | Value | Consumer |
|---|---|---|
| `org.opencontainers.image.version` | svxlink `PROJECT` version (`26.05.1`; master: `26.05.1+git.<sha7>`) | `svx status`/`svx update` display — the **primary** RuntimeIdentity (svxlink has no HTTP API) |
| `org.opencontainers.image.revision` | upstream sm0svx/svxlink commit SHA actually built | `svx update` change detection, bug reports |
| `org.opencontainers.image.source` | `https://github.com/dirkwa/svxlink-images` | provenance |
| `org.opencontainers.image.created` | real build timestamp (UTC) | `svx status` image age |
| `org.svxlink.image.channel` | `latest` \| `master` \| `manual` | **`svx update` guard**: refuses to restart onto an image whose channel label contradicts the configured channel |
| `org.svxlink.image.builder-sha` | this repo's commit | recipe forensics |
| `org.svxlink.image.sounds` | e.g. `en_US-heather-25.05` | informational (bug reports, sounds tooling) |
