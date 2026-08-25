# wq-dashboard (isws)

The ISWS water quality dashboard, served by Traefik at the host in
[`.env`](.env). One container, no database, no local state — its data lives in
an S3 bucket on OSN, reached with the credentials in `secrets.enc.env`.

Run everything below on the VM itself, as a user in the `docker` group.

```sh
stacks --vm isws ps wq-dashboard      # expect 1/1 running
stacks --vm isws logs wq-dashboard -f
```

## Basic auth

Traefik requires a basic-auth credential for every request to
`${WQ_DASHBOARD_HOST}` — there is no unauthenticated path, static assets
included. It is **one shared credential**, username `demo`, not per-user
accounts.

The credential lives in `secrets.enc.env` as `WQ_DASHBOARD_AUTH`, a single
htpasswd line (`demo:$2y$05$...`, bcrypt). The plaintext password is kept
alongside it as a comment in that same file — the whole file is encrypted, so
the comment is protected exactly as the values are, and it means handing the
login to someone does not depend on anyone having written it down elsewhere.

Two labels in [`docker-compose.yml`](docker-compose.yml) put it in front of the
router: one defining the `wq-dashboard-auth` middleware, one attaching it.

The bcrypt cost is htpasswd's default (5) on purpose. Traefik re-verifies the
hash on *every* request rather than caching a session, so a page load pays it
once per asset — `-C 12` would add a quarter-second to each of those.

### Rotating it

```sh
stacks --vm isws edit-secrets wq-dashboard   # change WQ_DASHBOARD_AUTH + the comment
git commit -am 'isws: rotate wq-dashboard demo credential'
stacks --vm isws up wq-dashboard             # `up`, not `restart` -- see docs/secrets.md
```

Generate the replacement line with
`htpasswd -nbB demo "$(openssl rand -base64 18)"`, and **do not double the `$`
characters** in it. Compose interpolation is single-pass, so a `$` inside the
value is never re-read; the `$$` rule applies only to a `$` typed literally into
`docker-compose.yml`.

Confirm the new credential took, and that the old one no longer works:

```sh
curl -s -o /dev/null -w '%{http_code}\n' https://wq-dashboard.isws.prairie.illinois.edu/
# 401 -- no credential
curl -s -o /dev/null -w '%{http_code}\n' -u demo:'the-new-value' \
  https://wq-dashboard.isws.prairie.illinois.edu/
# 200
```

## S3 credentials

Three values in `secrets.enc.env` — `S3_ENDPOINT`, `S3_ACCESS_KEY` and
`S3_SECRET_KEY` — point the application at its bucket on NCSA's OSN pod. They
are injected into the container's environment, which means they are readable via
`docker inspect` to anyone in the `docker` group; see [`docs/secrets.md`](../../../docs/secrets.md).

The same key pair is used by the pipeline that writes the bucket, so a rotation
there has to be mirrored here. Nothing detects the drift — it surfaces as the
dashboard failing to load data.

```sh
stacks --vm isws edit-secrets wq-dashboard
git commit -am 'isws: rotate wq-dashboard S3 credentials'
stacks --vm isws up wq-dashboard
```

## First bring-up

`WQ_DASHBOARD_HOST` has to resolve to this VM before Let's Encrypt will issue a
certificate for it. Until DNS is in place, point the traefik stack's
`TRAEFIK_ACME_CASERVER` at the staging endpoint rather than burning the
production rate limit on failed challenges — see [`../traefik/.env`](../traefik/.env).

## Image tags

`WQ_DASHBOARD_TAG` in [`.env`](.env) pins the image. The tag regex in
[`stack.conf`](stack.conf) matches `vN.N.N` only, which deliberately excludes
the `latest` tag that repository also publishes: a moving tag pinned in `.env`
defeats the point of pinning.
