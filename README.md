# ISWS VM configuration

Provisioning source of truth for the Illinois State Water Survey virtual machine.
Each service on the VM is a docker-compose **stack** under [`stacks/`](stacks/);
[`bin/stacks`](bin/stacks) brings them up in order at boot and manages their
pinned image tags.

> [!IMPORTANT]
> **This repository is public.**
> `stacks/*/.env` is committed on purpose — it holds pinned image tags and
> non-secret configuration. **Never put a secret in it.** Secrets go in
> `stacks/*/secrets.enc.env`, encrypted with [SOPS](https://getsops.io) and
> [age](https://age-encryption.org). See [docs/secrets.md](docs/secrets.md).

## Layout

| Path | What it is |
| --- | --- |
| `bin/stacks` | The only command you need. `stacks help` lists everything. |
| `lib/` | Shell helpers: stack discovery, compose invocation, registry queries. |
| `stacks/<name>/` | One stack. `docker-compose.yml`, `.env`, `secrets.enc.env`, `stack.conf`. |
| `stacks/_template/` | Copy this to start a new stack. Ignored by the CLI. |
| `systemd/` | The boot unit, plus an optional weekly update-report timer. |
| `docs/` | Bootstrap, secrets, adding a stack, updating images, troubleshooting. |

## Everyday commands

```sh
stacks status                  # what exists, what is running, what tag is pinned
stacks up                      # bring up every enabled stack, in order
stacks logs traefik -f         # follow one stack's logs
stacks bump                    # are there new releases? (read-only)
stacks edit-secrets traefik    # edit encrypted secrets in $EDITOR
```

On the VM these run as `/opt/isws-vm/bin/stacks`, and systemd runs `stacks up`
at boot. Logs: `journalctl -u isws-stacks -f`.

## The three routine tasks

**Take a new release** — [docs/updating-images.md](docs/updating-images.md)
```sh
stacks bump                    # see what is available
stacks bump --apply            # rewrite the pinned tags
git diff                       # review: one line per bumped tag
stacks pull && stacks up       # deploy
git commit -am 'bump traefik to v3.7.11' && git push
```

**Change a secret** — [docs/secrets.md](docs/secrets.md)
```sh
stacks edit-secrets traefik    # decrypts to $EDITOR, re-encrypts on save
git commit -am 'rotate traefik dashboard password'
stacks up traefik              # `up`, not `restart` -- see docs/secrets.md
```

**Add a stack** — [docs/adding-a-stack.md](docs/adding-a-stack.md)
```sh
cp -r stacks/_template stacks/myapp
$EDITOR stacks/myapp/stack.conf stacks/myapp/.env stacks/myapp/docker-compose.yml
stacks config myapp            # validate
stacks up myapp
```

## How it fits together

**Ordering.** Each `stack.conf` sets `ORDER` (ascending; `traefik` is `10`,
default `50`). `up` follows it, `down` reverses it. A stack that fails to start
does not stop the others — `up` reports the aggregate and exits `2`.

**Networking.** `traefik` owns ports 80 and 443 and terminates TLS. Every other
stack joins the shared external `edge` network and publishes itself with
`traefik.*` labels instead of binding host ports. `stacks up` creates `edge`
if it is missing, so no stack depends on another for it to exist.

**Secrets.** `stacks` runs compose under `sops exec-env`, which decrypts into
the environment of that one process. Plaintext is never written to disk. Because
ambient environment is compose's highest-precedence interpolation source, the
same values serve both `${VAR}` in `docker-compose.yml` and `environment: [VAR]`
pass-through into containers.

**Tags.** Every image is pinned in the stack's `.env` and declared in
`stack.conf`'s `IMAGES` list with a regex constraint. `stacks bump` queries the
registry, picks the highest `sort -V` match, and rewrites the `.env` in place —
comments and ordering preserved — so an upgrade is a reviewable one-line diff.

## Requirements

- Ubuntu 22.04+ (the VM) or macOS (for editing), Docker Engine with the Compose
  v2 plugin — `docker compose version` must work.
- `sops` ≥ 3.9 and `age` for secrets.
- `curl` and `jq` for `stacks bump` only.
- `bash` — runs on 3.2 (macOS system bash) and up.

New VM? Start at [docs/bootstrap.md](docs/bootstrap.md).
Something broken? [docs/troubleshooting.md](docs/troubleshooting.md).
