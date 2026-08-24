# dagster (isgs)

Dagster orchestration for the ISGS water data application, serving its UI through
Traefik at the host in [`.env`](.env), plus a one-shot job that prepares Dagster's
own database in the shared [`postgres`](../postgres/) cluster.

It ingests workbooks the [`waterdb`](../waterdb/) application uploaded to S3 and
writes them into that application's database. One image serves four roles --
Dagster requires its core version to match exactly across every process -- so the
code location, the webserver, the daemon and every run container all run
`ghcr.io/prairieresearchinstitute/isgs_waterdb-dagster`, selected by `command`.

Run everything below on the VM itself, as a user in the `docker` group.

## Four containers, one of them stopped

```sh
stacks --vm isgs ps dagster
```

| Container | Expected state | |
| --- | --- | --- |
| `dagster-provision` | `Exited (0)` | reconciles Dagster's own role and database |
| `dagster-code` | `Up (healthy)` | loads the definitions, serves them over gRPC on 4000 |
| `dagster-web` | `Up` | the UI |
| `dagster-daemon` | `Up` | ticks the sensors, launches runs |

**`stacks status` reports this stack as `3/4` running, and that is correct.** The
provisioning job is meant to exit; the stopped container is the record that it
ran. An `Exited (1)` is a real failure — read its logs.

A fifth kind of container appears and disappears while runs execute: **one run
container per run**, created by Dagster's `DockerRunLauncher` directly against the
host's Docker API. Those are not declared in
[`docker-compose.yml`](docker-compose.yml) — they are configured by
`run_launcher` in [`dagster.yaml`](dagster.yaml), inherit nothing from the compose
file, and are removed on exit.

Nothing here can `depends_on` the postgres stack's service. That stack is a
separate Compose project (`PROJECT=postgres` in its `stack.conf`), and
`depends_on` only resolves service names within one project. The chain instead
hangs off `dagster-provision`, which does its own bounded wait for the cluster.

## Two databases on one cluster

Do not conflate them:

| | Database | Role | Configured in |
| --- | --- | --- | --- |
| Dagster's **instance storage** — runs, event log, schedules, dynamic partitions | `dagster` | `dagster` | `storage:` in [`dagster.yaml`](dagster.yaml) |
| The **application** tables the assets read and write | `waterdb` | `waterdb` | `DATABASE_URL` in [`docker-compose.yml`](docker-compose.yml) |

Instance storage has to be Postgres and not the SQLite default: the webserver,
the daemon and every run container are separate processes that must share those
tables.

## Two object stores, too

Also distinct, and both off-host — there is no object store container on this VM:

| | Env vars | Read by | Bucket |
| --- | --- | --- | --- |
| `ObjectStoreResource` | `S3_*` | `data_logger`, `sonde_data` | parsed from the `s3://` URIs in the application database |
| `TaigaResource` | `TAIGA_*` | `discover_s3_folders`, `processed_graph_files` | `graphing-data`, hardcoded in the image |

The `TAIGA_*` path is the main ingestion route — the sensor that discovers new
folders and the asset that parses the workbooks both use it. The `S3_*` three are
copies of the [`waterdb`](../waterdb/) stack's; the `TAIGA_*` three are unique to
this stack.

**There is no `S3_BUCKET` variable.** Nothing in the image reads one.

## Deploy

```sh
stacks --vm isgs config dagster   # renders the compose file; catches missing vars
stacks --vm isgs up dagster
stacks --vm isgs logs dagster -f
```

`config` prints decrypted secrets to your terminal — do not redirect it to a
file, and be aware of your scrollback.

The stack needs the [`postgres`](../postgres/) stack up. A full
`stacks --vm isgs up` handles that: postgres is `ORDER=20` with `WAIT=1`, this is
`ORDER=60`. Bringing this one up on its own relies on the provisioning job's
60-second wait, which fails with a clear message naming the postgres stack.

The two host directories in [`.env`](.env) — `DAGSTER_STORAGE_DIR` and
`DAGSTER_SCRATCH_DIR` — are created by the daemon if absent and need nothing
prepared by hand. Unlike `WATERDB_DATA_DIR` they are not operator-staged input.

## Confirming it is healthy

Four checks, in order. The last one is the only thing that proves the shared
storage is wired correctly, and its failure mode is silent.

**1. Ingress and auth.**

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://dagster.isgs.prairie.illinois.edu/
# 401 -- no credential
curl -s -o /dev/null -w '%{http_code}\n' -u dagster:'the-password' \
  https://dagster.isgs.prairie.illinois.edu/
# 200
```

**2. The definitions loaded.** The UI lists **3 assets** and **3 sensors**. If the
deployment page shows the code location as failed, `docker logs dagster-code`: a
`dagster` core version mismatch or a missing environment variable shows up there.

**3. A sensor tick creates a separate run container.** Enable the sensors — they
tick every 30 seconds — then watch for a container that is *not* one of the four
above:

```sh
watch -n2 'docker ps --format "{{.Names}}\t{{.Image}}\t{{.Status}}"'
```

It runs the same `isgs_waterdb-dagster` tag as the rest of the stack, which is
what proves `DAGSTER_CURRENT_IMAGE` on `dagster-code` is right. Confirm it can
reach its dependencies — a run failing to resolve `postgres`, or timing out
against the S3 endpoint, means `run_launcher.config.networks` did not take:

```sh
docker inspect -f '{{json .NetworkSettings.Networks}}' <run-container>   # must include db
```

**4. That run's logs are readable in the UI afterwards.** Open the finished run
and expand a step's stdout/stderr. **This is the check that matters.** Op output
is written under `$DAGSTER_HOME/storage` inside a run container whose filesystem
is thrown away, so it only survives because the webserver, the daemon and the run
container all mount the same host directory. Get that wrong and every container
still looks healthy while the UI shows no logs at all.

```sh
ls -R /data/dagster/storage | head    # populated after a run
ls /data/dagster/scratch              # the CSV-writing asset's output
```

Empty after a completed run means the mount paths disagree between
[`docker-compose.yml`](docker-compose.yml) and
`run_launcher.config.container_kwargs.volumes` in [`dagster.yaml`](dagster.yaml).
Nothing checks that they match.

**Concurrency.** Trigger `discover_s3_folders` — one tick can request up to 25
runs — and confirm the run queue executes at most **2** at a time, the rest
`QUEUED`. The asset's `op_tags={"warehouse": "in_use"}` limits nothing on its own;
it needs the matching `run_queue.tag_concurrency_limits` entry in `dagster.yaml`,
and those runs each load a whole `.xlsx` workbook into memory.

## What the provisioning job does

[`provision-db.sh`](provision-db.sh) reconciles rather than creates, so running it
again is harmless:

- role `${DAGSTER_DB_USER}` — created if absent, otherwise its password is set to
  `DAGSTER_DB_PASSWORD` from `secrets.enc.env`
- database `${DAGSTER_DB_NAME}` — created if absent, owned by that role either way

It touches **only** Dagster's own role and database. The application's role and
database belong to the [`waterdb`](../waterdb/) stack and are reconciled by its
own job, even though Dagster connects to that database too.

It connects over the cluster's Unix socket, published on the host at
`${POSTGRES_SOCKET_DIR}` by the postgres stack, where `pg_hba.conf` says
`local all all trust`. So it needs no admin password, and none is stored here. See
[the postgres README](../postgres/README.md#publishing-the-socket) for what that
mount grants.

```sh
docker logs dagster-provision
# provision: creating role "dagster"
# provision: creating database "dagster"
# provision: done
```

Three values in [`.env`](.env) — `POSTGRES_SOCKET_DIR`, `POSTGRES_ADMIN_USER` and
`POSTGRES_TAG` — restate the postgres stack's own settings, and two more —
`WATERDB_DB_NAME`, `WATERDB_DB_USER` — restate the waterdb stack's. Nothing checks
that they match; one stack's `.env` cannot read another's. A wrong socket path
shows up as the job timing out after 60 seconds with a clear message.

## Basic auth

Traefik requires a basic-auth credential for every request to `${DAGSTER_HOST}`.
**Dagster OSS ships no authentication of its own**, and no host port is published
for it, so this middleware is the only thing in front of the UI.

> [!IMPORTANT]
> This is **not** the waterdb `demo` credential and must not be circulated like
> it. The waterdb credential guards a read-only web page; anyone who can reach the
> Dagster UI can launch and terminate runs, which is code execution on this VM.

The credential lives in `secrets.enc.env` as `DAGSTER_AUTH`, a single htpasswd
line (`dagster:$2y$05$...`, bcrypt), with the username and password recorded
alongside it as comments in the same encrypted file — the hash is not reversible.
Two labels in [`docker-compose.yml`](docker-compose.yml) put it in front of the
router: one defining the `dagster-auth` middleware, one attaching it.

The bcrypt cost is htpasswd's default (5) on purpose. Traefik re-verifies the hash
on *every* request rather than caching a session, and this UI is asset-heavy.

### Rotating it

```sh
stacks --vm isgs edit-secrets dagster    # change DAGSTER_AUTH and its comments
git commit -am 'isgs: rotate dagster UI credential'
stacks --vm isgs up dagster              # `up`, not `restart` -- see docs/secrets.md
```

Generate the replacement line with `htpasswd -nbB dagster "$(openssl rand -base64 24)"`,
and **do not double the `$` characters** in it. Compose interpolation is
single-pass, so a `$` inside the value is never re-read; the `$$` rule applies only
to a `$` typed literally into `docker-compose.yml`.

## Rotating the database passwords

`DAGSTER_DB_PASSWORD` is local to this stack:

```sh
stacks --vm isgs edit-secrets dagster
git commit -am 'isgs: rotate dagster instance-storage password'
stacks --vm isgs up dagster               # `up`, not `restart`
```

The changed value alters every container's configuration, so `up` recreates them
all: the provisioning job re-runs and the role's password follows. No SQL by hand.
Keep it **URL-safe** — `openssl rand -hex 32`, not `base64` — because
`dagster.yaml` interpolates it into a connection URI where `/ @ : ? # %` either
terminate the authority or get percent-decoded.

`WATERDB_DB_PASSWORD` and the three `S3_*` values are **copies of the waterdb
stack's**; the three `TAIGA_*` values are this stack's alone. Rotating any of them means editing *both* `secrets.enc.env` files and
bringing *both* stacks up. Nothing detects the drift; it surfaces as an
authentication failure the next time a sensor ticks.

Verify over TCP, so it exercises the real `scram-sha-256` path rather than the
trusted socket:

```sh
docker exec -e PGPASSWORD='the-new-value' postgres \
  psql -U dagster -h postgres -d dagster -tAc 'select current_user, current_database();'
# dagster|dagster
```

**Use `-h postgres`, not `-h 127.0.0.1`.** The generated `pg_hba.conf` includes
`host all all 127.0.0.1/32 trust`, so a loopback check succeeds with *any*
password, or none — it proves the role exists and nothing else.

## The Docker socket

`dagster-web` and `dagster-daemon` both mount `/var/run/docker.sock`
**read-write**. The daemon needs it to create a container per run; the webserver
needs it to terminate a run and to answer `canTerminate`.

**This is root-equivalent access to the host.** Anything that can talk to that
socket can start a privileged container and own the machine. It is defensible here
only because membership of the `docker` group is already root-equivalent on this
host — the same argument [Traefik](../traefik/) relies on. **Do not widen it**, and
do not "harden" it to `:ro`: creating and killing containers are API calls over the
socket, which a read-only bind does not prevent. It would look safer and change
nothing. If the threat model tightens, put a socket proxy in front of it and grant
only the container endpoints. See
[docs/adding-a-stack.md](../../../docs/adding-a-stack.md#note-on-the-docker-socket).

## Backups — not covered

The `dagster` database is new persistent state: run history, sensor cursors, and
dynamic partition registrations. **If it is lost, the cursor-driven sensors
reprocess their whole queue from scratch.**

There is no scheduled backup for the shared cluster today — see
[the postgres README](../postgres/README.md#dump-and-restore), which says so
outright. The application database is equally unprotected. Adding one is
outstanding work for that stack, not this one; the pattern to copy is
`systemd/vm-stacks-bump.timer`, and a `pg_dumpall` covers every database at once.

## Image tags

`DAGSTER_TAG` in [`.env`](.env) **must hold the same value as `WATERDB_TAG` in
[`../waterdb/.env`](../waterdb/.env)**. The Dagster image reads application tables
whose schema the web application owns, and the two are published together on one
GitHub release. There is no `latest` tag.

Nothing enforces it. `stacks bump` queries the two GHCR repositories
independently and will report a new tag for one and not the other:

```sh
stacks --vm isgs bump          # reports; never applies
```

Move both in one commit, then bring both stacks up:

```sh
stacks --vm isgs up dagster waterdb
```

**If the new image moves Dagster's own version, migrate instance storage before
trusting the daemon.** Dagster auto-*creates* its tables on an empty database but
never auto-*migrates* them:

```sh
docker exec dagster-web dagster instance migrate
```

Skipping it shows up as schema errors from the webserver or the daemon, which name
this command in the message.

`DAGSTER_CURRENT_IMAGE` on `dagster-code` is built from `DAGSTER_TAG`, so run
containers follow automatically — the tag is written in exactly one place per
stack. It is deliberately *not* set in `dagster.yaml`, which Compose does not
interpolate.

### The GHCR package must be public

The VM's Docker daemon pulls this image **twice over**: once via Compose for the
three long-lived services, and again directly, outside Compose, every time the run
launcher creates a run container. The `-dagster` package is new and GHCR packages
default to private.

`isgs_waterdb` and `isgs_waterdb-seed` are pulled anonymously today, so **make
`isgs_waterdb-dagster` public to match.** The alternative is two separate pieces of
plumbing: a `docker login` on the host for Compose, *and* registry credentials
under `run_launcher.config.registry` in `dagster.yaml` for the run containers — the
launcher does not read the host's `~/.docker/config.json`.
