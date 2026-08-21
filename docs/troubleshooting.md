# Troubleshooting

Symptoms, in the form you will actually see them.

## `cannot tell which VM this is`

```
error: cannot tell which VM this is -- hostname 'foo' matches no vm.conf HOSTNAMES
  known VMs: isgs isws odsc
```

Working as intended, and it means one of two things.

**On your laptop**: expected. Nothing there is a PRI VM. Name the VM:

```sh
stacks vms                     # what the names are
stacks --vm isws status
STACKS_VM=isws stacks status   # equivalent
```

**On a VM**: its hostname is not listed in `stacks/<vm>/vm.conf`. Compare:

```sh
hostname -s; hostname; hostname -f
grep HOSTNAMES /opt/vm-stacks/stacks/*/vm.conf
```

Fix it in the repo — add the name to that VM's `HOSTNAMES`, push, `git pull` —
rather than setting `STACKS_VM` on the box or adding it to the unit. The whole
point of hostname detection is that `vm-stacks.service` is identical everywhere,
so a host rename stays one reviewable commit.

A directory under `stacks/` with no `vm.conf` is not a VM at all and will not
appear in `stacks vms`.

**On a VM, also check the sparse checkout.** VMs are cloned with a sparse
checkout that includes only that machine's `stacks/<vm>/`, so a wrong name there
leaves no VM directory on disk at all and `stacks` reports `no VM directories
under .../stacks`. Confirm with `git sparse-checkout list` and `ls stacks`; see
[bootstrap.md §3](bootstrap.md#3-clone-the-repo-sparse).

## `stacks up` acted on the wrong VM's stacks

It cannot, unless you told it to. Check what it announced: every command that
touches stacks prints the VM first.

```
==> vm: isws -- Illinois State Water Survey VM
```

If that is wrong, something is setting `STACKS_VM` in your environment
(`echo $STACKS_VM`) or two VMs list the same name in `HOSTNAMES` — the first
match in alphabetical order wins, so make the lists disjoint.

## `Failed to get the data key` for one VM but not another

Expected. `.sops.yaml` has one rule per VM and each machine's key is a recipient
of its own VM's secrets only, so on `isws` you can read `stacks/isws/...` and
nothing else. See [secrets.md](secrets.md).

If you hit this on a **laptop**, that is different — your key should be a
recipient of every rule, so see the entry below.

## `network edge declared as external, but could not be found`

`edge` is `external: true` in every stack, so compose will not create it.
`stacks up` creates it first. You hit this by running `docker compose up` by hand
in a stack directory. Either use `stacks up`, or:

```sh
docker network create edge
```

## A new stack's secrets cannot be read on the VM

You encrypted the file with `--filename-override secrets.enc.env` — the bare
basename. The creation rules match on **path**, so that hit the catch-all rule,
which contains your laptop key and no VM key. Give the full repo-relative path
instead, or just use `stacks edit-secrets <stack>`, which passes the real path.
See [secrets.md](secrets.md).

## `stacks config` shows `$$apr1$$…` in a password hash

Not a corrupted value. `docker compose config` re-escapes every `$` so its output
is itself a valid, re-consumable compose file. The real value has single `$`.
Confirm on the running container:

```sh
docker inspect traefik --format \
  '{{ index .Config.Labels "traefik.http.middlewares.dashboard-auth.basicauth.users" }}'
```

Do not add `$$` to `docker-compose.yml` to "fix" it — that would break it.
Compose interpolation is single-pass, so a `$` arriving from a variable's value is
never re-interpolated.

## A container has `ENC[AES256_GCM,data:…]` as an environment value

You referenced `secrets.enc.env` from compose's `env_file:`. Compose read the
ciphertext verbatim. Secrets arrive as ambient environment via `sops exec-env`;
use `environment:` instead. See [secrets.md](secrets.md).

## `Failed to get the data key required to decrypt the SOPS file`

The age private key is missing or is not a recipient. In order of likelihood:

1. On macOS, sops's default keyfile lives in `~/Library/Application Support/sops/age/keys.txt`,
   not `~/.config`. `bin/stacks` probes both, but bare `sops` does not. Prefer
   `stacks updatekeys` / `stacks edit-secrets` over calling sops directly, or
   export the path yourself:

   ```sh
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
   ```

   This is the usual cause of a failed `sops updatekeys` on a fresh laptop.
2. The VM's public key was never added to **its own rule** in `.sops.yaml`, or
   `stacks updatekeys` was not run after adding it. Adding it to another VM's
   rule, or to the catch-all, does not help the machine that needs it.
3. `SOPS_AGE_KEY_FILE` points somewhere that does not exist. `bin/stacks` warns
   about this specifically.
4. On the VM, `/data` is not mounted, so `/data/secrets/age.key` is absent — the
   warning from (3) is the symptom. Check with `findmnt /data`. The boot unit
   carries `RequiresMountsFor=/data/secrets` so systemd waits for the volume,
   but a hand-run `stacks up` on a VM whose volume failed to mount will hit this.
5. You are reading another VM's secrets. That is by design — see the entry above.

## `stacks bump` reports a truncation error

```
registry error (myapp): tag list truncated at REGISTRY_MAX_PAGES=25; refusing to guess.
```

Working as intended: it would rather fail than report "up to date" from a partial
tag list. Raise the cap for that run:

```sh
REGISTRY_MAX_PAGES=60 stacks bump myapp
```

## `stacks bump` says `no tag matched /…/ out of N fetched`

Your regex is wrong, and it is telling you it did fetch tags. Check it against
reality:

```sh
curl -s 'https://hub.docker.com/v2/repositories/library/traefik/tags?page_size=100' \
  | jq -r '.results[].name' | grep -E '^v3\.[0-9]+\.[0-9]+$'
```

## `mapfile: command not found` or similar bash errors

Something is running the script with a bash older than 4 — macOS ships bash 3.2
as `/bin/bash`. The scripts are written to work on 3.2; if you see this, a change
introduced a bash-4-only builtin. Test with:

```sh
/bin/bash ./bin/stacks vms
/bin/bash ./bin/stacks --vm isws status
```

## `'docker compose' (Compose v2+) is not available`

Either Compose v1 is installed (`docker-compose`, hyphenated) or the CLI plugin
is not on the lookup path. On Docker Desktop the plugin lives under
`$HOME/.docker/cli-plugins`, so a wrong or empty `HOME` breaks it — worth knowing
when debugging anything that runs under systemd or `env -i`.

## Certificates are not being issued

In order of likelihood:

1. `TRAEFIK_ACME_CASERVER` is still the staging URL. Staging certificates are
   real but untrusted; browsers will warn. See
   [bootstrap.md §8](bootstrap.md).
2. Port 80 or 443 is not reachable from the internet. Both are required.
3. DNS for the hostname does not resolve to this VM.
4. Let's Encrypt rate limit hit while debugging on the production CA. Wait, or go
   back to staging until it works.

Traefik logs the ACME failure reason:

```sh
stacks logs traefik | grep -i acme
```

## Traefik will not start, complaining about `acme.json` permissions

Traefik requires mode `0600`. The stack uses a **named volume** precisely to
avoid this: Traefik creates the file itself inside the volume with correct
permissions. If someone converted it to a host bind mount, that is the cause.

## A stack failed but the others came up

By design — `stacks up` continues past a failing stack so one broken service
cannot keep the VM from booting. It reports the aggregate and exits `2`. Find the
failure:

```sh
stacks logs <stack> | tail -50
```

## Boot-time-only failures

Reproduce systemd's near-empty environment, which catches accidental dependencies
on your interactive shell (a PATH addition from `.zshrc`, an unexported variable):

```sh
env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
    SOPS_AGE_KEY_FILE=/data/secrets/age.key \
    /opt/vm-stacks/bin/stacks up
```

Note that `env -i` keeps `hostname` on `PATH`, so VM detection is exercised too —
which is worth knowing, because it is the one thing the boot path needs that an
interactive run gets for free.

And the real thing:

```sh
systemctl restart vm-stacks
journalctl -u vm-stacks -b --no-pager
```
