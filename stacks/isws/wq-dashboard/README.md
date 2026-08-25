# wq-dashboard (isws)

The ISWS water quality dashboard, served by Traefik at the host in
[`.env`](.env). One container, no database, no local state — its data lives in
an S3 bucket on OSN, reached with the credentials in `secrets.enc.env`.

Run everything below on the VM itself, as a user in the `docker` group.

```sh
stacks --vm isws ps wq-dashboard      # expect 1/1 running
stacks --vm isws logs wq-dashboard -f
```

## The application lives at `/dashboard`

The bare host serves nothing, so a `redirectRegex` middleware
(`wq-dashboard-root`) sends the root path there:

```
https://wq-dashboard.isws.prairie.illinois.edu/  ->  302  ->  .../dashboard
```

**Only the root path.** The regex is anchored `^(https?://[^/]+)/?$`, so `/` and
the empty path redirect and nothing else does — `/favicon.ico`, `/_app/...` and
every other asset is passed through untouched. This is deliberately not an
`addPrefix` middleware: that would rewrite the asset paths too and break the
very page it was meant to fix.

It is a **302, not a 301**. Browsers cache a permanent redirect indefinitely and
stop asking the server, so a 301 would have to be un-taught from every client
that ever hit it if the application later serves `/` itself.

The two middlewares are applied in the order listed on the router —
`wq-dashboard-auth,wq-dashboard-root` — auth first on purpose, so an anonymous
`GET /` gets a `401` rather than a redirect advertising where the application
actually lives.

The regex is typed literally into [`docker-compose.yml`](docker-compose.yml)
rather than arriving by interpolation, so its `$` characters **are** doubled
there (`$$`, and `$${1}` for the capture group). That is the opposite of the
`WQ_DASHBOARD_AUTH` rule below, and the distinction is the whole `$$` footgun:
doubling applies to a `$` you type into the compose file, never to one that
arrives inside an interpolated value.

Behaviour, all with a valid credential unless noted:

| Request | |
| --- | --- |
| `GET /` anonymous | `401` |
| `GET /` | `302` → `/dashboard` |
| `GET /dashboard` | `200` |
| `GET /favicon.ico`, `GET /_app/...` | `200`, not redirected |

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
