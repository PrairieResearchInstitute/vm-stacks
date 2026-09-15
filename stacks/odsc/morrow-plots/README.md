# morrow-plots (odsc)

Open WebUI instance for the Morrow Plots project, served at
`https://morrow-plots.odsc.prairie.illinois.edu` through the shared Traefik
proxy. Its application database lives in the dedicated
[`owui-postgres`](../owui-postgres/) cluster — not the unrelated `postgres`
stack that serves dagster — and this stack provisions its own role,
database, and the `vector` extension on every `up` (see `provision-db.sh`).

Run everything below on the VM itself, or from a laptop with `--vm odsc`.

## Bringing it up the first time

```sh
stacks --vm odsc up owui-postgres            # the dedicated cluster, first
stacks --vm odsc edit-secrets owui-postgres  # its own admin password, once
stacks --vm odsc edit-secrets morrow-plots   # fill in the two placeholders
rm stacks/odsc/morrow-plots/secrets.env.example
git add stacks/odsc/owui-postgres stacks/odsc/morrow-plots
git commit -m 'odsc: add owui-postgres and morrow-plots stacks'
stacks --vm odsc config morrow-plots         # renders compose, catches missing vars
stacks --vm odsc up morrow-plots
stacks --vm odsc logs morrow-plots -f
```

`up` brings up `morrowplots-provision` first and waits for it to exit 0
before starting `owui` — a failed provisioning run means `owui` is never
started at all, rather than started against a database that doesn't exist
yet.

## Status

```sh
stacks --vm odsc status
```

Reports this stack as 1/2 running once settled — `morrow-plots-provision`
sits `Exited (0)` on purpose, as the record that it ran; see
`docker logs morrow-plots-provision` for what it did.

## Where the data lives

Both under `/data/owui-datasherpa` — see the layout note at the top of
`.env` for the reasoning behind the split:

- `MORROWPLOTS_DATA_DIR` (`/data/owui-datasherpa/data/morrow-plots`) — OWUI's
  own app data: uploaded files, RAG index state, chat history. Irreplaceable
  if lost.
- `MORROWPLOTS_REPO_DIR` (`/data/owui-datasherpa/repos/morrow-plots`) — this
  project's own codebase, for code-generation Tools once that mount is
  uncommented in `docker-compose.yml`. Disposable — just a `git clone` away
  if lost.

## Rotating a secret

```sh
stacks --vm odsc edit-secrets morrow-plots
git commit -am 'odsc: rotate morrow-plots secret'
stacks --vm odsc up morrow-plots       # `up`, not `restart` -- see docs/secrets.md
```

A rotated `MORROWPLOTS_DB_PASSWORD` reaches the database too: `up` recreates
`morrowplots-provision`, whose job is to reconcile the role's password to
match on every run, not just the first.

## Adding this project's codebase for code-generation Tools

```sh
git clone <morrow-plots-codebase-url> /data/owui-datasherpa/repos/morrow-plots
```

Then uncomment the second `volumes:` line under the `owui` service in
`docker-compose.yml` and `stacks --vm odsc up morrow-plots`.

## Adding another project's chatbot (e.g. des)

```sh
cp -r stacks/odsc/morrow-plots stacks/odsc/des
```

Then, in the copy: rename every `morrowplots`/`morrow-plots`/`MORROWPLOTS`
occurrence to `des` throughout `stack.conf`, `.env`, `docker-compose.yml`,
and `provision-db.sh` (container names, router/service names in the Traefik
labels, the `MORROWPLOTS_*` variable names and their values, and both data
paths — `/data/owui-datasherpa/data/des` and `/data/owui-datasherpa/repos/des`);
set a real `DES_HOST`; then follow "Bringing it up the first time" above
(its `owui-postgres` cluster is already up by then — no need to repeat that
step). Also add it to the list in `stacks/odsc/owui-postgres/README.md`
"Provisioning a database for an application" — that list is what makes "who
has superuser on this cluster" answerable without grepping every compose
file.
