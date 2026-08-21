# Adding a stack

A stack belongs to exactly one VM: it lives at `stacks/<vm>/<name>/`. Two VMs
that run the same service each get their own directory — they have different
hostnames, different secrets, and upgrade on their own schedule.

Examples below use `isws`; substitute the VM you are working on. From the VM
itself the `--vm` flag is unnecessary.

## 1. Copy the template

```sh
cp -r stacks/_template stacks/isws/myapp
```

`stacks/_template` sits at the VM level and is shared by every VM. It is skipped
by VM discovery (leading underscore), so it can live there indefinitely.

## 2. Fill in `stack.conf`

```sh
DESCRIPTION="What this serves"
ORDER=50
ENABLED=1
NETWORKS="edge"
WAIT=0
PROJECT=myapp

IMAGES="
MYAPP_TAG ghcr.io/org/myapp ^v[0-9]+\.[0-9]+\.[0-9]+$
"
```

`ORDER` bands, by convention:

| Band | For |
| --- | --- |
| 10 | the edge proxy |
| 20–39 | shared infrastructure other stacks depend on (database, cache) |
| 40+ | applications |

Set `WAIT=1` only if later stacks genuinely need this one healthy first; it
makes `up` block on healthchecks.

## 3. Pin the tags in `.env`

```ini
MYAPP_TAG=v1.4.2
MYAPP_HOST=myapp.isws.prairie.illinois.edu
```

Committed, and public. No secrets here — see [secrets.md](secrets.md).

## 4. Publish through Traefik, not a host port

Join `edge` and add labels. **Do not bind host ports** — two stacks fighting
over `:443` is exactly what this arrangement exists to prevent.

```yaml
services:
  app:
    image: ghcr.io/org/myapp:${MYAPP_TAG}
    restart: unless-stopped
    environment:
      - MYAPP_TOKEN=${MYAPP_TOKEN:?MYAPP_TOKEN missing from secrets.enc.env}
    networks: [edge, internal]
    labels:
      traefik.enable: "true"
      traefik.docker.network: edge
      traefik.http.routers.myapp.rule: Host(`${MYAPP_HOST}`)
      traefik.http.routers.myapp.entryPoints: websecure
      traefik.http.routers.myapp.tls.certResolver: le
      traefik.http.services.myapp.loadbalancer.server.port: "8080"

  db:
    image: postgres:${POSTGRES_TAG}
    restart: unless-stopped
    networks: [internal]        # NOT on edge -- unreachable from the proxy
    volumes:
      - pgdata:/var/lib/postgresql/data

networks:
  edge:
    external: true
  internal:

volumes:
  pgdata:
```

Points worth copying:

- **Router and service names must be unique within the VM.** Traefik reads labels
  from every container on the machine at once, so `routers.app` in two stacks on
  the same VM collide. Name them after the stack. Across VMs there is no
  constraint — each has its own Traefik — so two VMs may both have
  `routers.myapp`.
- **`traefik.docker.network: edge`** tells Traefik which network to reach the
  container on. Required whenever a container is on more than one network.
- **`loadbalancer.server.port`** is the container-side port. Required whenever
  the image exposes more than one.
- **Anything that should not be reachable from the internet stays off `edge`.**
  A database on `internal` only is unroutable by Traefik by construction, not by
  configuration you could forget.
- **`${VAR:?message}`** for secrets, so a missing one fails loudly at startup.

## 5. Add secrets, if any

```sh
stacks --vm isws edit-secrets myapp
```

The path decides the recipients: `.sops.yaml` has one rule per VM, so a secret
under `stacks/isws/` is encrypted to your laptop and the isws machine, and to
nothing else. Nothing to configure per stack.

Delete `secrets.env.example` once the real encrypted file exists.

## 6. Validate, deploy, commit

```sh
stacks --vm isws config myapp  # renders the compose file; catches missing vars
stacks --vm isws up myapp
stacks --vm isws logs myapp -f
git add stacks/isws/myapp && git commit -m 'isws: add myapp stack'
```

`stacks config` warns that it prints decrypted secrets — do not redirect it to a
file.

## Parking a stack

Set `ENABLED=0` in `stack.conf` and it is skipped by `up`, `pull`, and `bump` on
that VM. Naming it explicitly (`stacks up myapp`) still works, which is the
intended escape hatch.

Disabling does not stop a running stack — `stacks up` warns if a disabled stack
still has containers, but will not tear it down, because `up` should never stop a
service you did not name. Stop it yourself:

```sh
stacks down myapp
```

## Moving a stack to another VM

`git mv stacks/isws/myapp stacks/odsc/myapp`, then, because the destination has a
different recipient list, re-key the secrets and change the hostnames:

```sh
stacks updatekeys                     # re-encrypts to odsc's rule
$EDITOR stacks/odsc/myapp/.env        # MYAPP_HOST, and anything else host-shaped
stacks --vm isws down myapp           # on the old machine
stacks --vm odsc up myapp             # on the new one
```

`updatekeys` can only re-key while a *current* recipient's private key is on the
machine you run it from — your laptop is a recipient of every rule, which is why
this works from there and not from either VM.

## Note on the Docker socket

Traefik mounts `/var/run/docker.sock` read-only to discover routes. Read-only
access to the socket is still effectively root on the host — anything that can
read it can enumerate and influence containers. It is the standard arrangement
for Traefik's docker provider and acceptable here; if the threat model tightens,
put a socket proxy in front of it and give Traefik only the container-list
endpoint.
