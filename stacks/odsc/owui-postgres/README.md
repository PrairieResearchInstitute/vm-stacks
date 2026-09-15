# owui-postgres (odsc)

A second, independent PostgreSQL server on this VM, alongside — not
replacing — [`postgres`](../postgres/). This one runs `pgvector/pgvector`
and exists purely so OWUI-based chatbots (starting with
[`morrow-plots`](../morrow-plots/)) can use vector similarity search for RAG
embeddings.

## Why a second Postgres server, instead of adding pgvector to `postgres`

`pgvector/pgvector:0.8.6-pg18` **is** `postgres:18.6` — same base image, same
entrypoint, same initdb, everything a plain Postgres server does, plus the
pgvector extension's files added. It is a strict superset: nothing is
removed or changed, so it could have replaced the image in the existing
`postgres` stack with zero loss of functionality for `dagster`, its only
current tenant.

That would have been the more "shared infrastructure" way to do it — one
cluster, every app's database in it, matching the pattern
[`postgres/README.md`](../postgres/README.md) documents. It was set aside
in favor of this separate stack specifically to avoid touching a stack that
dagster already depends on without first coordinating that change — not
because of any technical limitation. If `owui-postgres` proves itself and
the coordination happens later, folding it back into one cluster is a real
option; nothing here forecloses it.

The cost of the separate-cluster path is real, if modest: two Postgres
servers running on one VM instead of one, each with its own memory
footprint, its own directory to back up, its own image to keep patched.

## Where it differs from `postgres`, deliberately

Every value below had to be different from the other cluster's, or the two
would collide on the same host:

| | `postgres` | `owui-postgres` |
| --- | --- | --- |
| Container name | `postgres` | `owui-postgres` |
| Network | `db` | `owui-db` |
| Data directory | `/data/postgres` | `/data/owui-postgres` |
| Socket directory | `/run/postgresql` | `/run/owui-postgresql` |
| Admin role | `pgadmin` | `owui_pgadmin` |

Two Postgres servers cannot publish a Unix socket at the same path, or bind
mount two different clusters' data to the same host directory — either of
those would be a real collision, not just a naming preference.

Note `/data/owui-postgres` stays flat at the top of `/data`, not nested
under `/data/owui-datasherpa` — this cluster is shared infrastructure
serving every OWUI app, parallel to `postgres` itself, not one app
instance's own storage. `/data/owui-datasherpa` is where each individual
OWUI app's own data and codebase checkout live; see
[`morrow-plots/.env`](../morrow-plots/.env) for that layout.

## A psql shell

```sh
docker exec -it owui-postgres psql -U owui_pgadmin -d postgres
```

Same reasoning as [`postgres`](../postgres/README.md#a-psql-shell) — no
password needed over the socket, `-U` is still required since `docker exec`
enters as root. See that stack's README for the full set of one-off-command
and piping-SQL-in patterns; they apply here unchanged, just against this
cluster's container name and admin role.

## Provisioning a database for an application

Same pattern as [`postgres`](../postgres/README.md#provisioning-a-database-for-an-application):
a one-shot provisioning job in the *application's* stack, connecting over
this cluster's socket. [`morrow-plots`](../morrow-plots/) is the worked
example — its `provision-db.sh` also runs `create extension if not exists
vector` after creating its database, since that's the entire reason this
cluster exists.

Stacks that mount this cluster's socket — keep this list current, same
reasoning as `postgres/README.md`'s own list:

- [`morrow-plots`](../morrow-plots/) — its application database, plus pgvector

For a new OWUI app, in its stack's `.env`:

```ini
POSTGRES_SOCKET_DIR=/run/owui-postgresql   # NOT /run/postgresql
POSTGRES_ADMIN_USER=owui_pgadmin           # NOT pgadmin
```

and its `stack.conf`'s `NETWORKS` needs `owui-db`, not `db`.

## The admin password

Lives in this stack's own encrypted secrets, as `OWUI_POSTGRES_ADMIN_PASSWORD`:

```sh
stacks --vm odsc edit-secrets owui-postgres
```

Only needed for a network connection — the psql shell above uses the trusted
socket instead. As with `postgres`, this variable is read by `initdb` only
on first boot; rotating it in the secret alone changes nothing about an
already-running cluster. Update it in SQL too, same recipe as
[`postgres`](../postgres/README.md#the-admin-password).

## Where the data lives

`/data/owui-postgres` on the host, bind-mounted to `/var/lib/postgresql`.
The cluster itself is one level down, at `/data/owui-postgres/18/docker` —
same reasoning as `postgres`'s own data layout.

## Logs and state

```sh
stacks --vm odsc logs owui-postgres -f
stacks --vm odsc status
docker inspect --format '{{.State.Health.Status}}' owui-postgres
```
