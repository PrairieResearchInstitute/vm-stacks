# waterdb (isgs)

The ISGS water data application, served by Traefik at the host in
[`.env`](.env), plus two one-shot jobs that prepare its database in the shared
[`postgres`](../postgres/) cluster.

Run everything below on the VM itself, as a user in the `docker` group.

## Three containers, two of them stopped

```sh
stacks --vm isgs ps waterdb
```

| Container | Expected state | |
| --- | --- | --- |
| `waterdb-provision` | `Exited (0)` | reconciles the role and database |
| `waterdb-seed` | `Exited (0)` | loads the data into that database |
| `waterdb` | `Up` | the application |

They come up in exactly that order, chained by
`condition: service_completed_successfully` in
[`docker-compose.yml`](docker-compose.yml). Each link is a hard gate: if the
provisioning job fails, the seed never runs; if the seed fails, the application
is never started, rather than left serving an empty or half-loaded database.
Compose reports that as `dependency failed to start`.

**`stacks status` reports this stack as `1/3` running, and that is correct.** The
jobs are meant to exit; the stopped containers are the record that they ran. An
`Exited (1)` on either is a real failure — read its logs.

Nothing here can `depends_on` the postgres stack's service. That stack is a
separate Compose project (`PROJECT=postgres` in its `stack.conf`), and
`depends_on` only resolves service names within one project. The chain instead
hangs off `waterdb-provision`, which does its own bounded wait for the cluster.

## `stacks up waterdb` blocks until the seed finishes

The seeding job re-runs on every `up` and the application waits on it, so a
bring-up takes as long as a seed does. `WAIT=0` in [`stack.conf`](stack.conf)
does not bear on this — it only controls `--wait`, and a
`service_completed_successfully` dependency gets no `--wait-timeout`. The wait is
unbounded; interrupt it if a seed hangs.

A full `stacks --vm isgs up` is unaffected: `bin/stacks` runs each stack's `up`
under `|| true`, so a failure here does not stop the machine's other stacks.

## What the provisioning job does

[`provision-db.sh`](provision-db.sh) reconciles rather than creates, so running
it again is harmless:

- role `${WATERDB_DB_USER}` — created if absent, otherwise its password is set
  to `WATERDB_DB_PASSWORD` from `secrets.enc.env`
- database `${WATERDB_DB_NAME}` — created if absent, owned by that role either way

It connects over the cluster's Unix socket, published on the host at
`${POSTGRES_SOCKET_DIR}` by the postgres stack, where `pg_hba.conf` says
`local all all trust`. So it needs no admin password, and none is stored here —
this stack holds only the application's own credential. See
[the postgres README](../postgres/README.md#publishing-the-socket) for what that
mount grants.

```sh
docker logs waterdb-provision
# provision: role "waterdb" exists, reconciling its password
# provision: database "waterdb" exists, reconciling its owner
# provision: done
```

Three values in [`.env`](.env) — `POSTGRES_SOCKET_DIR`, `POSTGRES_ADMIN_USER` and
`POSTGRES_TAG` — restate the postgres stack's own settings. Nothing checks that
they match; one stack's `.env` cannot read another's. A wrong socket path shows up
as the job timing out after 60 seconds with a clear message.

## What the seeding job does

It loads the data staged on the host at `${WATERDB_DATA_DIR}` — bind-mounted at
`/data` — into the database the provisioning job just prepared. **That directory
is operator-staged input.** Nothing creates it for you; put the files there
before bringing the stack up.

```sh
ls /data/waterdb
docker logs waterdb-seed
```

Unlike the provisioning job, it connects over TCP as the application's own role,
so it is on the `db` network and gets no socket mount — seeding is not a
superuser job.

## Database access

Both the application and the seeding job get the same connection string,
assembled in `docker-compose.yml` from `.env` and `secrets.enc.env`:

```
postgresql://${WATERDB_DB_USER}:${WATERDB_DB_PASSWORD}@postgres:5432/${WATERDB_DB_NAME}
```

Host `postgres` resolves because both containers join the `db` network — listed
in `NETWORKS` in [`stack.conf`](stack.conf), which is what makes `stacks up`
create it, and joined as `external: true` in the compose file. The application is
on `edge` as well, which is why its `traefik.docker.network: edge` label is
required rather than decorative: with two networks, Traefik would otherwise have
two addresses to choose between.

**`WATERDB_DB_PASSWORD` has to be URL-safe.** It is interpolated into the URI
above, so `/ @ : ? # %` in it either terminate the authority or get
percent-decoded. Generate it with `openssl rand -hex 32`, not
`openssl rand -base64 33`. The role itself accepts any byte — the provisioning
job sets it with a quoted psql literal — so this constraint comes entirely from
the connection string.

## Rotating the database password

```sh
stacks --vm isgs edit-secrets waterdb    # change WATERDB_DB_PASSWORD
git commit -am 'isgs: rotate waterdb database password'
stacks --vm isgs up waterdb              # `up`, not `restart` -- see docs/secrets.md
```

The changed value alters every one of these containers' configuration, so `up`
recreates all three: the job re-runs and the role's password follows, the seed
re-runs, and the application restarts with the new string. No SQL by hand.
Confirm it took, over TCP so it exercises the real `scram-sha-256` path rather
than the trusted socket:

```sh
docker exec -e PGPASSWORD='the-new-value' postgres \
  psql -U waterdb -h postgres -d waterdb -tAc 'select current_user, current_database();'
# waterdb|waterdb
```

**Use `-h postgres`, not `-h 127.0.0.1`.** The generated `pg_hba.conf` includes
`host all all 127.0.0.1/32 trust`, so a loopback check succeeds with *any*
password, or none — it proves the role exists and nothing else. Only a connection
arriving from another address reaches the `scram-sha-256` line and actually tests
the credential.

## Image tags

`WATERDB_TAG` in [`.env`](.env) pins two images that are released together: the
application and `isgs_waterdb-seed`. `stacks bump` queries only the application's
repository, so a bump to a tag the seed image has not published leaves the
seeding job unpullable — and the application not started behind it.
