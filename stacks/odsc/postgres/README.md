# postgres (odsc)

PostgreSQL 18 for the odsc VM's applications. Reachable only from the private
`db` network — no host port is bound and nothing here joins `edge` — so all
administration goes through the container.

Run everything below on the VM itself, as a user in the `docker` group.

## A psql shell

```sh
docker exec -it postgres psql -U pgadmin -d postgres
```

**No password is needed for this.** psql connects over the Unix socket in
`/var/run/postgresql`, and the image's generated `pg_hba.conf` starts with
`local all all trust`. The admin password only applies to connections arriving
over the network, which is what the last line of that file covers:

```
local   all   all                     trust            # <- what the command above uses
host    all   all   127.0.0.1/32      trust
host    all   all   all               scram-sha-256    # <- appended by the entrypoint
```

`-U pgadmin` is still required. `docker exec` enters the container as **root**
(the image's entrypoint drops to the `postgres` user for the server process only),
so without `-U` psql tries to log in as `root` and you get:

```
FATAL:  role "root" does not exist
```

There is no `postgres` role either — `initdb` named the superuser after
`POSTGRES_ADMIN_USER`, so `pgadmin` is the only login role in a fresh cluster. If
you change that value in [`.env`](.env), it only affects a cluster built from
scratch; an existing role has to be renamed in SQL.

Useful once you are in:

```
\l              list databases
\du             list roles
\dt             list tables in the current database
\c myapp        connect to another database
\d mytable      describe a table
\x              toggle expanded output -- worth it for wide rows
\q              quit
```

## One-off commands

`-c` for a single statement:

```sh
docker exec postgres psql -U pgadmin -d postgres -c '\l'
docker exec postgres psql -U pgadmin -d postgres -c 'select version();'
```

`-tAc` when you want a bare value with no header, padding, or row count —
the form to use in a script:

```sh
docker exec postgres psql -U pgadmin -d postgres -tAc 'show data_directory;'
# /var/lib/postgresql/18/docker
```

Note `-it` is absent here. It is only needed for an interactive session; carrying
it into a script or a cron job makes docker refuse to run at all, because there is
no terminal to attach:

```
cannot attach stdin to a TTY-enabled container because stdin is not a terminal
```

## Piping SQL in

**`docker exec` needs `-i` or stdin is discarded.** Without it psql reads an
empty script, prints nothing, and exits 0 — the statements simply never run, with
no error to tell you so:

```sh
docker exec -i postgres psql -U pgadmin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
create role myapp with login password 'CHANGE-ME';
create database myapp owner myapp;
SQL
```

`-v ON_ERROR_STOP=1` matters for multi-statement input: psql's default is to
report a failed statement and carry on with the rest, then exit 0, so a broken
migration looks like a success.

A file works the same way:

```sh
docker exec -i postgres psql -U pgadmin -d postgres -v ON_ERROR_STOP=1 < migration.sql
```

## Publishing the socket

`POSTGRES_SOCKET_DIR` in [`.env`](.env) — `/run/postgresql` — is bind-mounted to
`/var/run/postgresql`, so the server's Unix socket appears on the host rather than
only inside the container. It is on `/run` and not `/data` deliberately: a socket
is runtime state, `/run` is tmpfs, and a stale socket that outlived its cluster
would give clients `ECONNREFUSED` instead of a clear “no such file”.

The point of publishing it is authentication. The first line of `pg_hba.conf` is
`local all all trust`, so **any container that mounts that directory is a
superuser on this cluster** — no password involved. That is what lets an
application stack provision its own role and database without a copy of
`POSTGRES_ADMIN_PASSWORD`, and it is also why the mount is not something to hand
out casually. It is defensible here only because membership of the `docker` group
is already root-equivalent on this host; see [docs/secrets.md](../../../docs/secrets.md).

No stack on this VM mounts it yet. When one does, add it here — the list is
what makes "who has superuser on this cluster" answerable without grepping every
compose file. For worked examples, the isgs VM has two:
[`waterdb`](../../isgs/waterdb/) and [`dagster`](../../isgs/dagster/), each
mounting it read-only from a one-shot provisioning container.

Check it from the host:

```sh
ls -l /run/postgresql          # .s.PGSQL.5432, owned by uid 999
```

## Provisioning a database for an application

The admin role is a superuser and applications should not use it. Give each one
its own role and database.

**Prefer a provisioning job in the application's own stack.**
[`waterdb`](../../isgs/waterdb/), on the isgs VM, is the worked example: a
one-shot container that mounts the socket directory above, reconciles its role
and database on every `stacks up`, and reads its password from its own stack's
`secrets.enc.env`. That keeps the app's credential in the app's stack, survives a
rebuild of this VM without anyone remembering to re-run anything, and makes
rotating the password an `edit-secrets` plus an `up` rather than hand-written
SQL. Copy `provision-db.sh` and the `waterdb-provision` service from that
stack's `docker-compose.yml`.

For a one-off, or to see what that job is doing, the manual equivalent is:

```sh
docker exec -i postgres psql -U pgadmin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
create role myapp with login password 'a-long-random-value';
create database myapp owner myapp;
SQL
```

Note this is create-once: run it twice and the second run fails on the existing
role, and it has no way to bring an already-created role's password back into
line with a rotated secret. The provisioning job exists precisely to close both
gaps.

Either way, that password belongs in the *application* stack's
`secrets.enc.env`, not this one — it is the app's credential. An app that talks
to the database over the network then connects over `db`:

```
postgresql://myapp:<password>@postgres:5432/myapp
```

For that to resolve, the application stack needs `db` in its `NETWORKS`
(`stack.conf`) and listed under `networks:` in its compose file as
`external: true`. Host `postgres` is this stack's service name.

Verify the credential before wiring up the app — over TCP, so it exercises the
real `scram-sha-256` path rather than the trusted socket:

```sh
docker exec -e PGPASSWORD='a-long-random-value' postgres \
  psql -U myapp -h postgres -d myapp -tAc 'select current_user, current_database();'
```

Passing the password as `-e PGPASSWORD` rather than typing it at the prompt keeps
it out of your shell history, but it is visible in `docker inspect` for the life
of that exec. Fine for a one-off check.

## The admin password

Needed only for a network connection — not for the `docker exec` shell above.
It lives in this stack's encrypted secrets as `POSTGRES_ADMIN_PASSWORD`:

```sh
stacks --vm odsc edit-secrets postgres
```

That opens the decrypted file in `$EDITOR` and re-encrypts on save. To rotate it,
change the value in SQL as well — `POSTGRES_PASSWORD` is only read by `initdb` on
first boot, so editing the secret alone changes nothing about the running cluster:

```sh
docker exec -i postgres psql -U pgadmin -d postgres <<'SQL'
alter role pgadmin with password 'the-new-value';
SQL
stacks --vm odsc edit-secrets postgres    # match the secret to what you just set
stacks --vm odsc up postgres              # `up`, not `restart` -- see docs/secrets.md
```

## Dump and restore

```sh
# one database
docker exec postgres pg_dump -U pgadmin -Fc -d myapp > /data/backups/myapp.dump

# roles, tablespaces, and every database
docker exec postgres pg_dumpall -U pgadmin > /data/backups/all.sql

# restore into an existing, empty database
docker exec -i postgres pg_restore -U pgadmin -d myapp --clean --if-exists < /data/backups/myapp.dump
```

`-Fc` (custom format) rather than plain SQL: it is compressed and lets
`pg_restore` do selective and parallel restores. Redirect on the *host* side, as
above, so the dump lands on `/data` and not inside the container's writable layer.

There is no scheduled backup for this stack yet.

## Where the data lives

`/data/postgres` on the host, bind-mounted to `/var/lib/postgresql`. The cluster
itself is one level down, at `/data/postgres/18/docker`:

```sh
docker exec postgres psql -U pgadmin -tAc 'show data_directory;'
```

The postgres:18 image moved `PGDATA` from `/var/lib/postgresql/data` to
`/var/lib/postgresql/<major>/docker` and declares the parent as its volume, which
is why the mount target is the parent and not the data directory. `18` in that
path is the major version: a future major upgrade means a new subdirectory and a
`pg_upgrade` or dump/restore, not just a tag bump. `POSTGRES_TAG`'s regex in
[`stack.conf`](stack.conf) is anchored to the 18 line so `stacks bump` cannot
cross that line on its own.

## Logs and state

```sh
stacks --vm odsc logs postgres -f
stacks --vm odsc status
docker inspect --format '{{.State.Health.Status}}' postgres
```

The healthcheck is `pg_isready`, with a 60s `start_period` because `initdb` on a
first boot takes appreciably longer than a restart against an existing cluster.
