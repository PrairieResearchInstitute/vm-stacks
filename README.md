# Prairie Research Institute VM stacks

Provisioning source of truth for the PRI virtual machines. One repo, several
machines: each VM has a directory under [`stacks/`](stacks/), and each service on
that VM is a docker-compose **stack** inside it. [`bin/stacks`](bin/stacks) brings
them up in order at boot and manages their pinned image tags.

| VM | Serves |
| --- | --- |
| `isws` | Illinois State Water Survey |
| `isgs` | Illinois State Geological Survey |
| `odsc` | Office of Data Stewardship and Computing |

> [!IMPORTANT]
> **This repository is public.**
> `stacks/<vm>/<stack>/.env` is committed on purpose — it holds pinned image tags
> and non-secret configuration. **Never put a secret in it.** Secrets go in
> `stacks/<vm>/<stack>/secrets.enc.env`, encrypted with
> [SOPS](https://getsops.io) and [age](https://age-encryption.org). See
> [docs/secrets.md](docs/secrets.md).

## Layout

| Path | What it is |
| --- | --- |
| `bin/stacks` | The only command you need. `stacks help` lists everything. |
| `lib/` | Shell helpers: VM and stack discovery, compose invocation, registry queries. |
| `stacks/<vm>/vm.conf` | One VM's identity: description and the hostnames it answers to. |
| `stacks/<vm>/<stack>/` | One stack. `docker-compose.yml`, `.env`, `secrets.enc.env`, `stack.conf`. |
| `stacks/_template/` | Copy this to start a new stack. Shared by every VM; ignored by the CLI. |
| `.sops.yaml` | Shared, at the root. One encryption rule per VM. |
| `systemd/` | The boot unit, plus an optional weekly update-report timer. |
| `docs/` | Bootstrap, secrets, adding a stack, updating images, troubleshooting. |

## Which VM am I acting on?

Every command acts on exactly one VM. It is chosen by, in order:

1. `--vm <name>`, accepted anywhere in the arguments
2. `$STACKS_VM`
3. the machine's own hostname, matched against `HOSTNAMES` in each
   `stacks/<vm>/vm.conf` (short name, `hostname`, and `hostname -f`, case-insensitively)

On a VM, (3) means no flag is ever needed — which is why
`systemd/vm-stacks.service` is byte-identical on all three machines. From your
laptop, where nothing matches, name the VM:

```sh
stacks vms                     # the VMs, and which one resolves here
stacks --vm isws status
STACKS_VM=isws stacks bump
```

Nothing is guessed. If none of the three resolves, the command fails rather than
touch the wrong machine's configuration.

## Everyday commands

Shown from a laptop; drop the `--vm` when you are on the VM itself.

```sh
stacks vms                            # which VMs exist, which one is this?
stacks --vm isws status               # what exists, what runs, what tag is pinned
stacks --vm isws up                   # bring up every enabled stack, in order
stacks --vm isws logs traefik -f      # follow one stack's logs
stacks --vm isws bump                 # are there new releases? (read-only)
stacks --vm isws edit-secrets traefik # edit encrypted secrets in $EDITOR
```

On a VM these run as `/opt/vm-stacks/bin/stacks`, and systemd runs `stacks up` at
boot. Logs: `journalctl -u vm-stacks -f`.

## The three routine tasks

**Take a new release** — [docs/updating-images.md](docs/updating-images.md)
```sh
stacks bump                    # see what is available
stacks bump --apply            # rewrite the pinned tags
git diff                       # review: one line per bumped tag
stacks pull && stacks up       # deploy
git commit -am 'isws: bump traefik to v3.7.11' && git push
```

**Change a secret** — [docs/secrets.md](docs/secrets.md)
```sh
stacks edit-secrets traefik    # decrypts to $EDITOR, re-encrypts on save
git commit -am 'isws: rotate traefik dashboard password'
stacks up traefik              # `up`, not `restart` -- see docs/secrets.md
```

**Add a stack** — [docs/adding-a-stack.md](docs/adding-a-stack.md)
```sh
cp -r stacks/_template stacks/isws/myapp
$EDITOR stacks/isws/myapp/{stack.conf,.env,docker-compose.yml}
stacks --vm isws config myapp  # validate
stacks --vm isws up myapp
```

## How it fits together

**One VM at a time.** `stacks/` holds VM directories, not stacks. A VM directory
is anything with a `vm.conf` in it; a stack is any directory inside one with a
`docker-compose.yml`. `stacks/_template` sits at the VM level and is skipped
because of the leading underscore, so one template serves every VM.

**Ordering.** Each `stack.conf` sets `ORDER` (ascending; `traefik` is `10`,
default `50`). `up` follows it, `down` reverses it. A stack that fails to start
does not stop the others — `up` reports the aggregate and exits `2`.

**Networking.** On each VM, `traefik` owns ports 80 and 443 and terminates TLS.
Every other stack joins that VM's shared external `edge` network and publishes
itself with `traefik.*` labels instead of binding host ports. `stacks up` creates
`edge` if it is missing, so no stack depends on another for it to exist.

**Secrets.** `stacks` runs compose under `sops exec-env`, which decrypts into the
environment of that one process. Plaintext is never written to disk. Because
ambient environment is compose's highest-precedence interpolation source, the
same values serve both `${VAR}` in `docker-compose.yml` and `environment: [VAR]`
pass-through into containers. `.sops.yaml` is shared but **scoped by path**: a
VM's age key is a recipient only of its own `stacks/<vm>/` secrets, so one
compromised machine does not expose the other two.

**Tags.** Every image is pinned in the stack's `.env` and declared in
`stack.conf`'s `IMAGES` list with a regex constraint. `stacks bump` queries the
registry, picks the highest `sort -V` match, and rewrites the `.env` in place —
comments and ordering preserved — so an upgrade is a reviewable one-line diff.

## Requirements

- Ubuntu 22.04+ (the VMs) or macOS (for editing), Docker Engine with the Compose
  v2 plugin — `docker compose version` must work.
- `sops` ≥ 3.9 and `age` for secrets.
- `curl` and `jq` for `stacks bump` only.
- `bash` — runs on 3.2 (macOS system bash) and up.

New VM? Start at [docs/bootstrap.md](docs/bootstrap.md).
Something broken? [docs/troubleshooting.md](docs/troubleshooting.md).
