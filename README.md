# svxlink-images

Unofficial multi-arch container images of [sm0svx/svxlink](https://github.com/sm0svx/svxlink)
(SvxLink — advanced repeater controller and EchoLink software for Linux),
built from source on Debian Trixie and published to GHCR. This is a
**builder repo**, not a fork — no SvxLink source lives here.

Companion repo: [svxlink-universal-installer](https://github.com/dirkwa/svxlink-universal-installer)
sets up a complete rootless-podman SvxLink node (audio, PTT, EchoLink,
optional dashboard) on Debian Trixie using these images. The contract
between the two repos is [docs/image-contract.md](docs/image-contract.md).

## Tags

Image: `ghcr.io/dirkwa/svxlink-server`

| Tag | Meaning | Mutability |
|---|---|---|
| `:latest` | newest upstream **release** (e.g. 26.05.1) | mutable — moves on new upstream releases and on builder-recipe changes |
| `:26.05.1` | that exact upstream release | content-stable: always the same upstream commit; re-pushed (new digest) if this repo's recipe changes. Pin the digest for byte-level immutability |
| `:26.05` | newest patch of the 26.05 series | mutable within the series |
| `:master` | newest upstream master snapshot (≤3 h lag) | mutable |
| `:master-<sha7>` | exactly that upstream commit | content-stable |
| `:git-<sha7>` | manual one-off build (`manual.yml`) | content-stable |

`org.opencontainers.image.revision` on any tag names the exact upstream
commit inside:

```bash
podman image inspect ghcr.io/dirkwa/svxlink-server:latest \
  --format '{{index .Labels "org.opencontainers.image.revision"}}'
```

Architectures: `linux/amd64` + `linux/arm64` (one manifest list; native
runners, no QEMU).

## Usage

The image runs **one process per container**, selected by CMD
(`svxlink` default, `remotetrx`, `svxreflector`; anything else is exec'd
verbatim as a debug shell). It expects a config tree bind-mounted at
`/etc/svxlink` — seed one from the image's pristine copy:

```bash
cid=$(podman create ghcr.io/dirkwa/svxlink-server:latest)
podman cp "$cid":/etc/svxlink/. ./svxlink-etc/
podman rm "$cid"

podman run -d --name svxlink \
  --network host \
  --device /dev/snd --group-add keep-groups \
  -v ./svxlink-etc:/etc/svxlink \
  ghcr.io/dirkwa/svxlink-server:latest
```

- **Host networking is strongly recommended**: EchoLink registers the
  observed UDP source address (5198/5199) with the directory server; NAT
  breaks it.
- Audio/PTT device access under rootless podman: `--device /dev/snd`
  plus `--group-add keep-groups` with the invoking user in the host
  `audio` group (CM108 hidraw PTT additionally needs a host udev rule).
  The installer automates all of this.
- Optional file logging for log-scraping dashboards: set
  `SVXLINK_LOGFILE=/var/log/svxlink/svxlink` and mount a host dir at
  `/var/log/svxlink`. Rotation (`.1` sibling) and stdout mirroring are
  built in — see [docs/image-contract.md](docs/image-contract.md).
- Voice prompts: a pinned `en_US` pack is baked at
  `/usr/share/svxlink/sounds/en_US`. Add a language by mounting a host
  dir at `/usr/share/svxlink/sounds/<LANG>`. **Never mount
  `/usr/share/svxlink` or `.../sounds` wholesale** — that hides the TCL
  event handlers and the baked pack.

## Licensing

The build/CI recipes in this repo are Apache-2.0 ([LICENSE](LICENSE)).
The published images **redistribute SvxLink binaries licensed under the
GNU GPL** (see upstream [COPYRIGHT](https://github.com/sm0svx/svxlink/blob/master/COPYRIGHT));
the corresponding source for any image is the upstream commit named by its
`org.opencontainers.image.revision` label, plus this repo (build scripts) at
`org.svxlink.image.builder-sha`. The baked voice pack
([svxlink-sounds-en_US-heather](https://github.com/sm0svx/svxlink-sounds-en_US-heather))
is GPL-2.0.

## Maintenance

See [AGENTS.md](AGENTS.md) — including the state-gate semantics (upstream
key **plus** recipe hash; recipe pushes trigger builds directly) and the
"things that look wrong but aren't" list. Read it before changing the
Dockerfile.
