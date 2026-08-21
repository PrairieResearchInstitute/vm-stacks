# Updating images

Every image is pinned to an exact tag in its stack's `.env`. `stacks bump` finds
newer tags and rewrites those files; it never pulls, restarts, or deploys.
Deploying stays a separate, deliberate step.

`bump` is scoped to one VM, like every other command: it only looks at
`stacks/<vm>/*/.env`. Each machine upgrades on its own schedule, and a bump
commit touches one VM's files.

## The workflow

Run on the VM, where the VM is detected from the hostname:

```sh
git -C /opt/vm-stacks pull --ff-only
stacks bump                      # read-only report
stacks bump --apply              # rewrite the .env files
git diff                         # review: one line per bumped tag
stacks pull                      # fetch the new images
stacks up                        # converge, traefik first
stacks status                    # verify
git commit -am 'isws: bump traefik to v3.7.11' && git push
```

From a laptop, the check is read-only and worth doing across the fleet:

```sh
for vm in isws isgs odsc; do stacks --vm "$vm" bump; done
```

Applying from a laptop works too (`stacks --vm isws bump --apply`), but the
deploy still has to happen on the machine, so it is usually less confusing to do
both there.

`stacks bump --apply --deploy` collapses the last four steps for when you are
confident. It only pulls and re-ups the stacks whose tags actually changed. Do
not use it from a laptop — `--deploy` talks to the local Docker daemon, which is
not the VM's.

## Declaring what to track

Two places per image. In `.env`, the pinned tag:

```ini
TRAEFIK_TAG=v3.7.11
```

In `stack.conf`, one `IMAGES` line saying where to look and what counts:

```sh
IMAGES="
TRAEFIK_TAG traefik ^v3\.[0-9]+\.[0-9]+$
"
```

Columns are `<ENV_VAR> <image-ref-without-tag> <tag-regex>`.

The registry is inferred from the reference:

| Reference | Registry |
| --- | --- |
| `nginx` | Docker Hub, `library/` |
| `grafana/grafana` | Docker Hub namespace |
| `ghcr.io/org/app` | GitHub Container Registry |
| `quay.io/org/app` | Quay |
| `registry.example.org/org/app` | any OCI registry, anonymous pull |

## The regex is the policy

This is the part worth thinking about. The regex is what decides which upgrades
are automatic, and it is your only guard against nonsense. Docker Hub carries
over 2500 tags for `traefik` alone, including every v1 and v2 release and Windows
variants like `v3.7.11-nanoserver-ltsc2022`.

| Intent | Regex |
| --- | --- |
| Stay on the v3 line, releases only | `^v3\.[0-9]+\.[0-9]+$` |
| Stay on v3.7 patches only | `^v3\.7\.[0-9]+$` |
| Any stable semver, `v` prefix | `^v[0-9]+\.[0-9]+\.[0-9]+$` |
| Any stable semver, no prefix | `^[0-9]+\.[0-9]+\.[0-9]+$` |
| Pin major 12 | `^12\.[0-9]+$` |
| Alpine variant, pinned major | `^1\.[0-9]+\.[0-9]+-alpine$` |

Always anchor both ends. `^v3\.` alone would match
`v3.7.11-windowsservercore-ltsc2022`. Anchoring also excludes pre-releases
structurally — `^v[0-9]+\.[0-9]+\.[0-9]+$` cannot match `v3.8.0-rc1` — which is
far more reliable than trying to reason about how a version sort handles
pre-release suffixes.

Crossing a major version is deliberately not automatic. When you are ready to
move from v3 to v4, read the upgrade notes, then widen the regex.

## Rolling back

Edit the tag in `.env` and converge:

```sh
$EDITOR stacks/isws/traefik/.env   # back to the previous tag
stacks up traefik
```

No pull is usually needed — the previous image is still in the local cache.

## What `bump` will not do

**It never guesses.** If the registry is unreachable, if the tag list had to be
truncated, or if nothing matched your regex, `bump` reports a failure and exits
non-zero. It will not report "up to date" when it could not actually check.

That guard matters more than it sounds. The OCI `/tags/list` endpoint returns
tags in arbitrary order, and page 1 of `docker.io/library/traefik` contains zero
`v3.x.y` tags — a truncated walk that quietly returned what it happened to find
would report "up to date" forever and never surface a security release. If you
see a truncation error, raise the cap:

```sh
REGISTRY_MAX_PAGES=60 stacks bump myapp
```

**Selection is by version, never by recency.** Docker Hub's
`ordering=last_updated` puts Windows rebuilds of old branches first, so the most
recently pushed tag is routinely not the newest version. `bump` sorts matches
with `sort -V` and takes the highest.

**It never runs at boot.** Nothing on the `stacks up` path reaches the network
except pulling an image that is genuinely missing, so a registry outage cannot
stop the VM from booting.

## Why the weekly timer only reports

`systemd/vm-stacks-bump.timer` runs `stacks bump` — the dry run — and writes to
the journal. Being on the VM, it reports on that VM's stacks only:

```sh
journalctl -u vm-stacks-bump --since '1 week ago'
```

Making it `--apply --deploy` would let an unreviewed image change take the site
down at 03:00 with nobody watching. If you want that automated later, the right
shape is CI opening a pull request against this repo, not the VM mutating itself.
