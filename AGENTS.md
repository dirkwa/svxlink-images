# Agent guide — svxlink-images

This repo builds unofficial container images of
[sm0svx/svxlink](https://github.com/sm0svx/svxlink) from source. It is a
**builder**, not a fork — no SvxLink source lives here. It is the sibling of
[signalk-server-images](https://github.com/dirkwa/signalk-server-images)
(same skeleton) and the producer side of the contract in
`docs/image-contract.md`, consumed by
[svxlink-universal-installer](https://github.com/dirkwa/svxlink-universal-installer).
**`docs/image-contract.md` is normative** — the installer's CI greps this
repo's raw files; renaming an env var or a path listed there breaks
installations, not just builds.

## Mental model

Two channels + a manual escape hatch, one Dockerfile, one reusable build core:

| Workflow | Trigger | Ref built | Tags |
|---|---|---|---|
| `build-latest.yml` | every 6 h + recipe pushes | newest release tag → resolved commit SHA | `:latest`, `:26.05.1`, `:26.05` |
| `build-master.yml` | every 3 h (+15 min) + recipe pushes | master HEAD SHA | `:master`, `:master-<sha7>` |
| `manual.yml` | workflow_dispatch | any ref → resolved SHA | `:git-<sha7>` (+ extra tag) |

All three call `.github/workflows/_build.yml`: native-runner matrix
(amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`) pushing by digest
only, then one merge job assembling the manifest list with
`docker buildx imagetools create`. Per-arch digests travel through an
artifact round-trip because matrix job outputs don't aggregate.

There is **no beta channel**: upstream has no prereleases/RC tags. If one
ever appears, copy `build-latest.yml` and filter on prereleases.

### State gate = upstream key PLUS recipe hash

Every scheduled run resolves upstream identity and compares
`"<upstream> ctx:<hash>"` against `state/*.txt`, where `<hash>` comes from
`scripts/ctx-hash.sh` (Dockerfile + entrypoint.sh + the build action +
`_build.yml`, **plus the calling workflow's own file passed as an extra
arg** — without that, a push touching only build-latest.yml/build-master.yml
would trigger a run whose gate still said changed=false, and no cron could
ever self-heal it). Unlike the signalk reference — whose gate keys ONLY on
upstream, so Dockerfile changes sat unbuilt until upstream moved (its
documented gotcha) — a recipe change here rebuilds via **two independent
mechanisms**: the `push:` paths trigger gives immediacy, the ctx hash makes
the cron self-healing if that push run failed. Don't remove either "because
the other covers it". `state/` is excluded from the push paths and state
commits carry `[skip ci]`, so state pushes can never retrigger.

## Things that look wrong but aren't — read before "fixing"

- **`PROJECT=`, never `SVXSERVER=`, from `src/versions`.** `SVXSERVER=0.0.7`
  is an unrelated helper's version; f4hlv/svxlink-docker ships every image
  labelled 0.0.7 because of this. If the version looks frozen, check which
  key you're reading before "fixing" the parser.
- **`git init` + `fetch --depth=1 origin <ref>` instead of `clone --branch`.**
  `--branch` rejects raw commit SHAs, and CI always passes the gate-resolved
  SHA — that's what makes image contents provably match the `revision`
  label. Don't "simplify" back to clone.
- **The runtime stage installs the CPack `.deb`, not `make install`, and its
  apt list is tiny on purpose.** `-DCPACK_DEBIAN_PACKAGE_SHLIBDEPS=ON`
  generates `Depends:` from the actually-linked sonames, so a hand-curated
  runtime lib list (f4hlv's approach — incomplete there) cannot skew. The
  hand list is only non-library tooling: tzdata, procps, alsa-utils,
  init-system-helpers, ca-certificates.
- **`svxlink --version` inside the install RUN is a build assertion** (the
  analogue of signalk's `canSocket.node` test). If SHLIBDEPS ever
  under-declares, the build fails loudly instead of shipping a broken image.
- **Native runners everywhere; there is no QEMU action in this repo.** Every
  stream compiles C++; emulated arm64 is hours vs ~10-15 min native. Don't
  add a QEMU single-pass action back.
- **No `USER` directive — the container runs as root-in-userns.** Rootless
  podman maps container uid 0 to the invoking host user: bind mounts stay
  host-user-owned and the installer never needs `UserNS=keep-id` (which
  breaks device-node groups when combined with `keep-groups`,
  podman#28364). Adding a uid-1000 user "for security" breaks the
  installer's mount and log-permission model — see the contract doc.
- **`LC_ALL=C`, no `locales` package.** The CN8VX dashboard parses
  month-name log timestamps with C-locale regexes. Installing locales can
  silently localize timestamps and blank the dashboard.
- **`SVXLINK_LOGFILE` file mode + in-entrypoint rotation.** Looks like a
  container anti-pattern ("log to stdout") — it is the documented contract
  with the read-only log-scraping dashboard sidecar; stdout still gets
  everything via `tail -F` (started BEFORE svxlink so the banner is never
  lost). The single `.1` rotation sibling is load-bearing (the dashboard
  reads exactly LOGFILE and LOGFILE.1).
- **`SVXLINK_CONF` is not set in the image ENV.** The entrypoint defaults it
  per program (`/etc/svxlink/<prog>.conf`) so `podman run … remotetrx`
  picks remotetrx.conf; a global ENV would pin every CMD to svxlink.conf.
  The installer's quadlet sets it explicitly.
- **No `HEALTHCHECK`.** Under Quadlet it spawns a transient healthcheck
  timer per container with no consumer acting on "unhealthy" — pure journal
  noise on a Pi. `svx health` probes from the host. Also never gate health
  on log freshness: idle repeaters legitimately log nothing for hours.
- **No `START_*` env compatibility with f4hlv/svxlink-docker.** Its
  multi-process sh supervisor kept the container "up" after svxlink crashed.
  One supervised process per container; systemd `Restart=` owns recovery;
  remotetrx/svxreflector are one CMD away.
- **Sounds pinned at 25.05 while the code is 26.05.x.** Voice packs lag code
  releases upstream by months by design; not a stale pin.
- **The sounds stage depends only on the `SOUNDS_*` ARGs** — it is its own
  BuildKit DAG node, so the 14 MB download re-runs only when the pin moves,
  not on every upstream commit. It sits first purely for readability; the
  stage order is not what provides the caching.
- **All three `FROM` lines are literal `debian:trixie-slim`, no base ARG.**
  Dependabot's docker parser cannot resolve ARG-parameterized FROMs; a
  parameterized base silently opts out of digest-bump PRs.
- **`state/*.txt` are committed by the workflows themselves** via
  `scripts/commit-state.sh` (rebase+retry, up to 5 attempts). The git
  history is the audit trail. Don't simplify to a plain `git push`.

## Change recipes

- **Bumping the sound pack**: new release appears on
  `sm0svx/svxlink-sounds-en_US-heather` → `curl -L <asset-url> | sha256sum`
  → update `SOUNDS_VERSION` + `SOUNDS_SHA256` ARG defaults in the
  Dockerfile → commit. The push trigger + ctx hash rebuild both channels;
  no state reset needed. Also verify the unpacked layout still has `Core/`
  (the build asserts it).
- **Bumping the version floor**: `MIN_VERSION` in `build-latest.yml`.
- **New base image**: edit the three literal `FROM debian:trixie-slim`
  lines (kept literal so dependabot's docker parser sees them; verify the
  first weekly dependabot run actually offers digest bumps — if not, bump
  by hand).
- **Adding a variant channel**: copy `build-master.yml`, change resolver,
  state file, tags; reuse `_build.yml` unchanged.
- **Anything touching entrypoint env names, mount paths, labels, the user
  model, or tags**: update `docs/image-contract.md` in the same commit and
  coordinate an installer release — its `check-image-contract.sh --remote`
  tests against this repo's raw files.

## Conventions

- Angular conventional commits (`feat(workflows): …`, `chore(state): …`).
- No Co-Authored-By trailers, no "Generated with" attribution anywhere.
- Never push without an explicit "push"/"merge" instruction. Commit ≠ push.
- Never create PRs unless asked; this repo is direct-to-main.
- No emojis in commits, files, or comments unless explicitly asked.
- Dense why-comments naming the observed failure a line prevents.

## Pitfalls / scars (GHCR facts, inherited from the reference repo)

- **GHCR ACL stuckness.** After flipping package visibility/repo-source,
  per-arch manifests of already-pushed tags can keep the old ACL (anonymous
  index 200, anonymous per-arch manifest 404). Cure: delete the tag and
  re-push; >5000-download tags can't be deleted — overwrite via workflow
  re-run with a state reset.
- **`permissions: packages: write` is clamped by the repo default.**
  Settings → Actions → Workflow permissions must be "Read and write"
  (`gh api -X PUT /repos/…/actions/permissions/workflow`), else GHCR push
  401s despite the YAML.
- **`ubuntu-24.04-arm` runners are free for PUBLIC repos only** — the repo
  must be public before the first arm64 build. GitHub may rename the label;
  dependabot won't catch runner labels.
- **Package settings UI lags reality** after deletions; trust
  `gh api /user/packages/…/versions`.

## Verification

Local smoke build + entrypoint matrix:

```bash
podman build --build-arg SVXLINK_REF=26.05.1 -t svxlink-server:test .
podman run --rm svxlink-server:test svxlink --version

# config present, stdout mode
cid=$(podman create svxlink-server:test); podman cp "$cid":/etc/svxlink/. /tmp/svx-etc/; podman rm "$cid"
podman run --rm -v /tmp/svx-etc:/etc/svxlink svxlink-server:test   # logs to stdout

# file mode + rotation (see docs/image-contract.md for the env contract)
podman run --rm -v /tmp/svx-etc:/etc/svxlink -v /tmp/svx-log:/var/log/svxlink \
  -e SVXLINK_LOGFILE=/var/log/svxlink/svxlink svxlink-server:test
```

Anonymous-pull check against GHCR:

```bash
TOKEN=$(curl -sS "https://ghcr.io/token?service=ghcr.io&scope=repository:dirkwa/svxlink-server:pull" | jq -r .token)
curl -sS -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/dirkwa/svxlink-server/tags/list" | jq .
```
