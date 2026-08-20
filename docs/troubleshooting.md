# Troubleshooting

Symptoms, in the form you will actually see them.

## `network edge declared as external, but could not be found`

`edge` is `external: true` in every stack, so compose will not create it.
`stacks up` creates it first. You hit this by running `docker compose up` by hand
in a stack directory. Either use `stacks up`, or:

```sh
docker network create edge
```

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
2. The VM's public key was never added to `.sops.yaml`, or `sops updatekeys` was
   not run after adding it.
3. `SOPS_AGE_KEY_FILE` points somewhere that does not exist. `bin/stacks` warns
   about this specifically.

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
/bin/bash ./bin/stacks status
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
    SOPS_AGE_KEY_FILE=/etc/isws-vm/age.key \
    /opt/isws-vm/bin/stacks up
```

And the real thing:

```sh
systemctl restart isws-stacks
journalctl -u isws-stacks -b --no-pager
```
