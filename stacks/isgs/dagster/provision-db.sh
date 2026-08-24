#!/usr/bin/env bash
#
# Reconcile this stack's role and database in the shared postgres cluster.
#
# Dagster's INSTANCE STORAGE only -- the run, event log, schedule and dynamic
# partition tables it keeps for itself. The application's own database and role
# belong to the waterdb stack and are provisioned by its own job; this one never
# touches them, even though Dagster connects to that database as well.
#
# Runs as a one-shot container on every `stacks up dagster` and is idempotent by
# construction: it converges on what .env and secrets.enc.env say the role and
# database should be, rather than creating them, so a second run is a no-op and a
# rotated DAGSTER_DB_PASSWORD reaches the role on the next `up`.
#
# It connects over the Unix socket the postgres stack publishes, where
# pg_hba.conf says `local all all trust`, so no admin password is needed here --
# and therefore none has to be copied into this stack's secrets. That is the
# whole reason this job lives in the application's stack rather than in the
# postgres stack. Copied from ../waterdb/provision-db.sh; see the postgres
# stack's README.md, which prescribes exactly this.

set -euo pipefail

# Socket, not TCP: this container has network_mode: none. PGDATABASE is the
# cluster's bootstrap database -- `create database` cannot be run from inside
# the database it is creating.
export PGHOST=/var/run/postgresql
export PGUSER=${POSTGRES_ADMIN_USER:?POSTGRES_ADMIN_USER missing from .env}
export PGDATABASE=postgres

: "${DAGSTER_DB_NAME:?DAGSTER_DB_NAME missing from .env}"
: "${DAGSTER_DB_USER:?DAGSTER_DB_USER missing from .env}"
: "${DAGSTER_DB_PASSWORD:?DAGSTER_DB_PASSWORD missing from secrets.enc.env}"

# `stacks up` with no arguments brings postgres up first and blocks on its
# healthcheck -- ORDER=20 with WAIT=1, against ORDER=60 here -- so the cluster is
# already accepting connections. `stacks up dagster` on its own carries no such
# guarantee, hence a bounded wait rather than an immediate failure.
#
# Exits non-zero when it gives up: a job that quietly succeeded without
# provisioning anything would leave the webserver and daemon with nowhere to put
# their tables and nothing in the logs to say why.
for attempt in $(seq 1 30); do
  pg_isready -q && break
  if (( attempt == 30 )); then
    echo "provision: postgres not reachable on $PGHOST after 60s" >&2
    echo "provision: is the postgres stack up? (stacks --vm isgs up postgres)" >&2
    exit 1
  fi
  sleep 2
done

# One psql session doing its own branching, so a lookup and the DDL it decides
# on cannot be separated by anything.
#
# The values arrive through `printenv` inside \set rather than as `psql -v`
# arguments, which keeps the password out of the process's argv. Interpolating
# them as :"usr" quotes them as an identifier and as :'pw' as a string literal,
# so psql does the escaping and no value needs sanitising here.
#
# `create database` has no IF NOT EXISTS and cannot run inside a transaction,
# which is why this is a lookup plus a conditional rather than one statement.
psql -q -v ON_ERROR_STOP=1 <<'SQL'
\set usr `printenv DAGSTER_DB_USER`
\set db  `printenv DAGSTER_DB_NAME`
\set pw  `printenv DAGSTER_DB_PASSWORD`

select not exists (select 1 from pg_roles where rolname = :'usr') as need_role \gset
\if :need_role
  \echo 'provision: creating role' :'usr'
  create role :"usr" with login password :'pw';
\else
  \echo 'provision: role' :'usr' 'exists, reconciling its password'
  alter role :"usr" with login password :'pw';
\endif

select not exists (select 1 from pg_database where datname = :'db') as need_db \gset
\if :need_db
  \echo 'provision: creating database' :'db'
  create database :"db" owner :"usr";
\else
  \echo 'provision: database' :'db' 'exists, reconciling its owner'
  alter database :"db" owner to :"usr";
\endif
SQL

# No `grant` on schema public is needed: since PG15 that schema is owned by
# pg_database_owner, so owning the database is enough for Dagster to run its own
# schema migrations in it on first start.
echo "provision: done"
