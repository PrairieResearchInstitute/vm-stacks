#!/usr/bin/env bash
#
# Reconcile this stack's role, database, and pgvector extension in the
# DEDICATED owui-postgres cluster (see stacks/odsc/owui-postgres/) -- not the
# unrelated `postgres` stack that serves dagster. Modeled directly on
# stacks/isgs/waterdb/provision-db.sh -- see that file for the
# fully-annotated original; only the pgvector addition at the bottom is
# specific to this stack.
#
# Idempotent by construction: converges on what .env and secrets.enc.env say
# the role/database should be, rather than creating them outright, so a
# second run is a no-op and a rotated MORROWPLOTS_DB_PASSWORD reaches the role
# on the next `up`.
#
# It connects over the Unix socket the owui-postgres stack publishes, where
# pg_hba.conf says `local all all trust`, so no admin password is needed here
# -- and therefore none has to be copied into this stack's secrets.

set -euo pipefail

# Socket, not TCP: this container has network_mode: none. PGDATABASE is the
# cluster's bootstrap database -- `create database` cannot be run from inside
# the database it is creating.
export PGHOST=/var/run/postgresql
export PGUSER=${POSTGRES_ADMIN_USER:?POSTGRES_ADMIN_USER missing from .env}
export PGDATABASE=postgres

: "${MORROWPLOTS_DB_NAME:?MORROWPLOTS_DB_NAME missing from .env}"
: "${MORROWPLOTS_DB_USER:?MORROWPLOTS_DB_USER missing from .env}"
: "${MORROWPLOTS_DB_PASSWORD:?MORROWPLOTS_DB_PASSWORD missing from secrets.enc.env}"

# `stacks up` with no arguments brings owui-postgres up first and blocks on
# its healthcheck -- ORDER=25 with WAIT=1, against ORDER=50 here -- so the
# cluster is already accepting connections. `stacks up morrow-plots` on its
# own carries no such guarantee, hence a bounded wait rather than an
# immediate failure.
for attempt in $(seq 1 30); do
  pg_isready -q && break
  if (( attempt == 30 )); then
    echo "provision: postgres not reachable on $PGHOST after 60s" >&2
    echo "provision: is the owui-postgres stack up? (stacks --vm odsc up owui-postgres)" >&2
    exit 1
  fi
  sleep 2
done

# One psql session doing its own branching, so a lookup and the DDL it decides
# on cannot be separated by anything. Values arrive through `printenv` inside
# \set rather than as `psql -v` arguments, keeping the password out of the
# process's argv; :"usr" quotes as an identifier, :'pw' as a string literal,
# so psql does the escaping.
psql -q -v ON_ERROR_STOP=1 <<'SQL'
\set usr `printenv MORROWPLOTS_DB_USER`
\set db  `printenv MORROWPLOTS_DB_NAME`
\set pw  `printenv MORROWPLOTS_DB_PASSWORD`

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

# pgvector addition (not in the waterdb original): enable the extension
# INSIDE this stack's own database, never in the `postgres` bootstrap database
# above. \c is safe to interpolate directly here -- MORROWPLOTS_DB_NAME is our
# own configured value, not external input, unlike the password/role handling
# above which deliberately avoids direct interpolation.
#
# By this point the database above is guaranteed to exist, whether this run
# just created it or it already existed, so \c cannot fail here.
psql -q -v ON_ERROR_STOP=1 <<SQL
\c ${MORROWPLOTS_DB_NAME}
create extension if not exists vector;
SQL

echo "provision: done"
