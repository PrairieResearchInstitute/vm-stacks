# dagster (odsc)

[Dagster](https://dagster.io/) running the ERA5-Land ingest for the Office of
Data Stewardship and Computing. It downloads ERA5-Land from the Copernicus
Climate Data Store one month at a time, writes an Icechunk store and parquet
outputs to the Taiga bucket, and does not touch any application database.

The image is `ghcr.io/prairieresearchinstitute/dagster-pri`, built from
[`PrairieResearchInstitute/dagster-pri`](https://github.com/PrairieResearchInstitute/dagster-pri).
**That repo's `docs/deploy.md` is the authority for everything this stack
assumes** — the complete set of variables the image reads, the container roles,
the volumes and their ownership. This README covers only what is specific to
running it on this VM.

> [!NOTE]
> This stack was originally copied from the [`isgs`](../../isgs/dagster/) one,
> which deploys a *different* Dagster image with a split code-location/webserver/
> daemon layout, a `DockerRunLauncher`, an application database and a second
> object store. None of that applies here. If you are diffing the two, expect
> them to disagree; this one follows `docs/deploy.md`.

## Two containers, one of them stopped

| Container | What it is |
| --------- | ---------- |
| `dagster-provision` | One-shot job: reconciles Dagster's role and database in the shared cluster, then exits `0` and stays as the record that it ran. |
| `dagster` | Webserver, daemon and code location in one process tree. Published through Traefik, behind basic auth; no host port. |

One container, not four, because that is the shape the image is built for: its
default `CMD` is `all`, which starts the daemon and the webserver side by side,
and runs execute as subprocesses of that container via `DefaultRunLauncher`.

`stacks status` therefore reports **1/2 running**, which is correct and not a
fault.

**There is no run container and no Docker socket.** The image ships only its own
dependencies and `dagster_docker` is deliberately not among them, so an instance
config naming `DockerRunLauncher` cannot work — the image's startup preflight
rejects one outright rather than failing later, at the first run. Run isolation
here is `DAGSTER_MAX_CONCURRENT_RUNS` plus this container's limits.

**There is no `dagster.yaml` or `workspace.yaml` in this directory.** The image
ships both, and the baked instance config reads the `DAGSTER_PG_*` variables set
in [`docker-compose.yml`](docker-compose.yml). If you ever do need to override
it, mount your file at `/opt/dagster/home/dagster.yaml` and keep its
`local_artifact_storage` and `compute_logs` blocks — dropping them does not
disable local storage, it relocates it under `$DAGSTER_HOME` and quietly strands
the volume this stack mounts.

## One database, one bucket

Dagster's **instance storage** — runs, event log, schedules, sensor cursors,
dynamic partitions — is a `dagster` database owned by a `dagster` role in the
shared [`postgres`](../postgres/) cluster, reconciled by the provisioning job
below. That is the whole of this stack's relational footprint.

Everything else lives in the object store: the Icechunk stores, the parquet
outputs, and the two inputs that have to be there *before the first run*. The
layout is fixed by the image and is not configurable:

| Prefix in `${BUCKET_NAME}` | Written by |
| -------------------------- | ---------- |
| `shapefiles/state-watershed/IL/il_huc8_clip_mask.parquet` | **you, before the first run** |
| `pri_data/stations.csv` | **you, before the first run** |
| `era5-land/icechunk/IL/` | `era5_init`, `era5_iceberg` |
| `era5-land/parquet/STATE=…/YEAR=…/MONTH=…/` | `daily_station_readings` |
| `era5-land/hourly/STATE=…/YEAR=…/MONTH=…/` | `hourly_station_readings` |

Without the clip mask every run fails with a message naming the exact key and
the script in the image's repo that builds one
(`scripts/extract-huc8-clip-mask.py`).

## Before the first `up`

Two host directories have to exist **and be owned by uid 1000** — the image runs
as uid/gid 1000, and Docker creates a missing bind-mount source as root:

```sh
install -d -o 1000 -g 1000 /data/dagster/local /data/dagster/scratch
```

`/data/dagster/local` holds compute logs (op stdout/stderr, which is what the UI
reads back for a finished run) and must persist. `/data/dagster/scratch` is
`TMPDIR` inside the container, where a whole month of NetCDF is staged; it needs
room but not persistence.

Getting this wrong fails in two different ways — the entrypoint cannot install
`dagster.yaml`, or Dagster silently cannot write compute logs — and the image's
preflight catches both at startup and prints the exact `chown` to run.

## Deploy

```sh
stacks --vm odsc config dagster   # renders the compose file; catches missing vars
stacks --vm odsc up dagster
stacks --vm odsc logs dagster -f
```

`config` prints decrypted secrets to your terminal — do not redirect it to a
file, and be aware of your scrollback.

The stack needs the [`postgres`](../postgres/) stack up. A full
`stacks --vm odsc up` handles that: postgres is `ORDER=20` with `WAIT=1`, this is
`ORDER=40`. Bringing this one up on its own relies on the provisioning job's
60-second wait, which fails with a clear message naming the postgres stack.

The container does **not** require the cluster to be reachable at start — the
preflight does no database I/O on purpose — so a restart during a postgres
outage comes up and retries rather than crash-looping.

## Confirming it is healthy

**1. Ingress and auth.**

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://dagster.odsc.prairie.illinois.edu/
# 401 -- no credential
curl -s -o /dev/null -w '%{http_code}\n' -u dagster:'the-password' \
  https://dagster.odsc.prairie.illinois.edu/
# 200
```

**2. The code location loaded.** The UI's deployment page lists location
`dagster_pri.definitions` as loaded, with **3 assets** and the
`era5_monthly_sensor`. A failure here is a missing or misnamed environment
variable and shows up in `docker logs dagster`.

**3. Every required daemon is healthy.** Status → Daemons in the UI, or:

```sh
docker exec dagster dagster instance info
```

**4. A finished run's logs are readable in the UI.** Open a completed run and
expand a step's stdout/stderr. Empty means `/data/dagster/local` is not writable
by uid 1000 — every container still looks healthy while the UI shows no logs at
all.

```sh
ls -R /data/dagster/local | head    # populated after a run
```

## First ingest

The sensor ships **`STOPPED`** and `ERA5_START_YM` governs where it begins.
Neither is a default you want to discover later: with the sensor stopped, or
with `ERA5_START_YM` unset, the deployment looks entirely healthy and ingests
nothing.

1. Upload the clip mask and `pri_data/stations.csv` to `${BUCKET_NAME}`.
2. Bring the stack up; confirm the code location loads.
3. Run the `era5_init` job once for `IL`.
4. Start `era5_monthly_sensor` in the UI, or:

```sh
docker exec dagster dagster sensor start era5_monthly_sensor
```

It then advances one month at a time from `ERA5_START_YM`, skipping months whose
parquet has already landed, until it reaches `ERA5_END_YM` — empty in
[`.env`](.env), meaning it keeps up with ERA5-Land as new months are published.

`DAGSTER_MAX_CONCURRENT_RUNS=2` is what keeps a backfill from taking the VM's
memory with it: runs execute inside the `dagster` container, and one ERA5 month
is staged and processed whole. Raise it only after watching what one run costs.

## What the provisioning job does

[`provision-db.sh`](provision-db.sh) reconciles rather than creates, so running it
again is harmless:

- role `${DAGSTER_DB_USER}` — created if absent, otherwise its password is set to
  `DAGSTER_DB_PASSWORD` from `secrets.enc.env`
- database `${DAGSTER_DB_NAME}` — created if absent, owned by that role either way

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
`POSTGRES_TAG` — restate the postgres stack's own settings. Nothing checks that
they match; one stack's `.env` cannot read another's. A wrong socket path shows
up as the job timing out after 60 seconds with a clear message.

Note that the job reaches the cluster over the **socket** while the `dagster`
container reaches it over **TCP** on the `db` network: the image's baked
`dagster.yaml` has no socket form.

## Basic auth

Traefik requires a basic-auth credential for every request to `${DAGSTER_HOST}`.
**Dagster OSS ships no authentication of its own**, and no host port is published
for it, so this middleware is the only thing in front of the UI.

> [!IMPORTANT]
> Anyone who can reach this UI can launch and terminate runs, which is code
> execution on this VM. Treat the credential accordingly.

The credential lives in `secrets.enc.env` as `DAGSTER_AUTH`, a single htpasswd
line (`dagster:$2y$05$...`, bcrypt), with the username and password recorded
alongside it as comments in the same encrypted file — the hash is not reversible.
Two labels in [`docker-compose.yml`](docker-compose.yml) put it in front of the
router: one defining the `dagster-auth` middleware, one attaching it.

The bcrypt cost is htpasswd's default (5) on purpose. Traefik re-verifies the hash
on *every* request rather than caching a session, and this UI is asset-heavy.

> [!WARNING]
> This is currently the **same credential as the isgs Dagster UI**, inherited
> from the copy this stack started as. Two VMs sharing one password for a UI that
> executes code is worth undoing: rotate this one and leave isgs alone.

### Rotating it

```sh
stacks --vm odsc edit-secrets dagster    # change DAGSTER_AUTH and its comments
git commit -am 'odsc: rotate dagster UI credential'
stacks --vm odsc up dagster              # `up`, not `restart` -- see docs/secrets.md
```

Generate the replacement line with `htpasswd -nbB dagster "$(openssl rand -base64 24)"`,
and **do not double the `$` characters** in it. Compose interpolation is
single-pass, so a `$` inside the value is never re-read; the `$$` rule applies only
to a `$` typed literally into `docker-compose.yml`.

## Rotating the database password

`DAGSTER_DB_PASSWORD` is local to this stack — nothing else on this VM uses it:

```sh
stacks --vm odsc edit-secrets dagster
git commit -am 'odsc: rotate dagster instance-storage password'
stacks --vm odsc up dagster               # `up`, not `restart`
```

The changed value alters both containers' configuration, so `up` recreates them:
the provisioning job re-runs and the role's password follows. No SQL by hand.
Keep it **URL-safe** — `openssl rand -hex 32`, not `base64` — because Dagster
interpolates it into a connection URI where `/ @ : ? # %` either terminate the
authority or get percent-decoded.

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

## Rotating the object-store and CDS credentials

`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (Taiga) and `CDSAPI_KEY` are read
straight from the environment by the image's resources, so a rotation is an
`edit-secrets` and an `up`; nothing caches them.

> [!NOTE]
> `CDSAPI_KEY` is currently the same key as the one in the `dagster-pri`
> development `.env`. If a shared development/production key matters here, issue
> a separate one for this deployment and replace it.

The endpoint and bucket are **not** secret and live in [`.env`](.env) as
`AWS_ENDPOINT_URL` and `BUCKET_NAME`. The names are the standard AWS SDK ones
because that is what the image reads — `S3_ENDPOINT`, `S3_ACCESS_KEY`,
`S3_SECRET_KEY` and `S3_BUCKET` are read by nothing, and the image's preflight
rejects a container that sets them instead of the `AWS_*` ones.

## Backups — not covered

The `dagster` database is persistent state: run history, sensor cursors and
dynamic partition registrations. Losing it does not lose ingested data — that is
in the bucket, and the sensor rediscovers where it got to by listing landed
parquet — but it does lose the run history.

There is no scheduled backup for the shared cluster today; see
[the postgres README](../postgres/README.md#dump-and-restore), which says so
outright. Adding one is outstanding work for that stack, not this one; a
`pg_dumpall` covers every database at once.

## Image tags

`DAGSTER_TAG` in [`.env`](.env) is the GitHub release tag verbatim
(`0.1.0-alpha.2` → `:0.1.0-alpha.2`). Pre-releases produce **no `latest` and no
`0.1` alias**, so the full four-component tag is always written out. Nothing else
on this VM has to move with it.

```sh
stacks --vm odsc bump          # reports; never applies
```

The regex in [`stack.conf`](stack.conf) is anchored to the `0.1.0-alpha.N` line
and stops before a beta, an rc, or the first stable release — each of which is a
deliberate edit there plus a matching tag in `.env`.

**If a new image moves Dagster's own version, migrate instance storage before
trusting the daemon.** Dagster auto-*creates* its tables on an empty database but
never auto-*migrates* them:

```sh
docker exec dagster dagster instance migrate
```

Skipping it shows up as schema errors from the webserver or the daemon, which name
this command in the message.

### The GHCR package must be public

The VM's Docker daemon pulls this image through Compose and has no credentials
for GHCR. `dagster-pri` is published from a new repository and GHCR packages
default to private, so **make the package public** — the alternative is a
`docker login` on the host, which is state outside this repo that nothing here
reconciles.
