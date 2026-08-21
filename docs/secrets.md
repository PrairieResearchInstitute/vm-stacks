# Secrets

## Threat model, in three sentences

This repository is public, so every secret is stored encrypted at rest with SOPS
and age. `bin/stacks` decrypts only into the memory of the compose process it is
about to run — nothing is ever written to disk in plaintext. Once a value is
injected into a container's environment or a compose label, it *is* visible via
`docker inspect` to anyone in the `docker` group, so it is protected in the repo,
not on the running host.

Membership in the `docker` group is root-equivalent. Keep it small.

## One `.sops.yaml`, one rule per VM

[`.sops.yaml`](../.sops.yaml) is a single shared file at the repo root — recipient
lists are exactly the kind of thing that goes wrong when scattered, and
`stacks updatekeys` re-keys the whole repo in one pass against it.

But it is **scoped by path**. There is one `creation_rules` entry per VM:

```yaml
creation_rules:
  - path_regex: stacks/isws/.*secrets\.enc\.(env|yaml|json)$
    age: >-
      <laptop key>,
      <isws VM key>
  - path_regex: stacks/isgs/.*secrets\.enc\.(env|yaml|json)$
    age: >-
      <laptop key>
  ...
  - path_regex: secrets\.enc\.(env|yaml|json)$      # catch-all, laptop only
```

So a machine is a recipient of its own VM's secrets and nothing else. A
compromise of `isws` does not hand over `isgs` and `odsc`. The consequence you
will actually notice: on a VM, `sops` can decrypt `stacks/<its own vm>/...` and
fails on the others. That is correct behaviour, not a misconfiguration.

Rules are matched **in order, first match wins**, so the per-VM rules must stay
above the catch-all. The catch-all deliberately lists no VM key: a secret not
scoped to a machine has no business being readable by one.

Adding a VM means adding a rule. Adding a machine or a person to an existing VM
means adding their public key to that VM's rule — and only that one.

## Keys

Each machine that needs to read secrets has its own age keypair. The **public**
keys are listed in `.sops.yaml`; the private keys never leave their machine and
are never committed.

| Where | Private key location | Can decrypt |
| --- | --- | --- |
| Your laptop (Linux) | `~/.config/sops/age/keys.txt` | every VM |
| Your laptop (macOS) | `~/Library/Application Support/sops/age/keys.txt` | every VM |
| `isws` | `/data/secrets/age.key`, `root:root`, mode `0600` | `stacks/isws/` only |
| `isgs` | same path on that machine | `stacks/isgs/` only |
| `odsc` | same path on that machine | `stacks/odsc/` only |

A laptop is a recipient of every rule because that is where `stacks updatekeys`
has to run: a re-key must decrypt before it can re-encrypt, so it only works from
a machine holding a current recipient's key for each file it touches. No VM can
do that for the whole repo, and none should be able to.

Each VM's key sits on `/data`, a persistent volume, rather than under `/etc`.
`/etc` is on the root filesystem, so rebuilding the machine would destroy the
key and force a full re-key: new keypair, new entry in that VM's rule in
`.sops.yaml`, `stacks updatekeys` from a laptop, commit, push. On `/data` the VM
keeps its identity as a recipient across a rebuild and none of that is needed.

That macOS path is the single most common "works on the VM, not on my laptop"
cause: sops resolves its default keyfile through Go's `os.UserConfigDir()`, which
is `~/Library/Application Support` on macOS but `~/.config` on Linux.
`bin/stacks` sidesteps it by probing both locations and exporting
`SOPS_AGE_KEY_FILE` itself, so either path works. An explicit
`SOPS_AGE_KEY_FILE` in the environment always wins — that is what the systemd
unit sets on the VM.

### Generating a key

```sh
age-keygen -o ~/.config/sops/age/keys.txt      # prints the public key
chmod 600 ~/.config/sops/age/keys.txt
```

### Adding a recipient

Adding a machine or a person means adding their public key **to the right VM's
rule** and re-encrypting the data key on every existing file:

```sh
$EDITOR .sops.yaml             # ADD the age1... key to that VM's rule
stacks updatekeys              # re-encrypts every VM's secrets files
git commit -am 'sops: add <name> as a recipient of <vm>'
```

`stacks updatekeys` is the one command that ignores the VM selection and walks
every VM, by design: `.sops.yaml` is shared, so a change to it can affect any of
them, and re-keying half the repo is how you end up with a file no key on any
machine can read. It reports per-file failures rather than stopping, so a file
you legitimately cannot decrypt does not block the rest.

**Add, never replace.** The recipients are a comma-separated list and any one of
them can decrypt. If you overwrite the entry instead of appending to it, the
re-key removes the old recipient — and if that was the only key able to decrypt
on your machine, you lose access. The diff `updatekeys` prints before acting is
worth reading: `+++` is a key being added, `---` is one being removed.

Use `stacks updatekeys` rather than bare `sops updatekeys`. It applies the same
age-key discovery as the rest of the CLI, so it works regardless of which of the
two platform default paths your key lives in. Running sops directly on macOS
with a key in `~/.config` fails with a confusing "no key could decrypt" error —
export `SOPS_AGE_KEY_FILE` first if you must.

Note the ordering constraint: a re-key has to **decrypt** before it can
re-encrypt, so it only works while a private key for one of the file's *current*
recipients is available on the machine you run it from.

### Adding a VM

```yaml
  - path_regex: stacks/<vm>/.*secrets\.enc\.(env|yaml|json)$
    age: >-
      <laptop key>
```

Above the catch-all, laptop key only, until the machine exists and has generated
its own keypair — see [bootstrap.md §0 and §5](bootstrap.md). A VM with no rule of
its own falls through to the catch-all, which no VM key is in, so its secrets
would be undecryptable on the machine that needs them. The symptom is a
decryption failure at `stacks up`, not a silent misencryption.

### Removing a recipient

`sops updatekeys` after removing the key stops that key from reading *future*
versions. It does **not** un-read what that key already had access to. Treat a
removed recipient as a disclosed secret: remove the key **and** rotate the
values.

## Working with secrets

### Editing

```sh
stacks --vm isws edit-secrets traefik
```

Decrypts into `$EDITOR`, re-encrypts on save. Creates the file if absent.

### Rotating a value

```sh
stacks --vm isws edit-secrets traefik
git commit -am 'isws: rotate traefik dashboard credential'
stacks --vm isws up traefik
```

`up`, not `restart`. Compose reads secrets at container-create time; `restart`
bounces the existing container with its existing environment, so a rotated
secret would not take effect. `up` notices the changed configuration and
recreates.

### Rotating the encryption key without changing values

```sh
sops rotate -i stacks/isws/traefik/secrets.enc.env
```

### Creating one from scratch

The creation rules in `.sops.yaml` match on **path**, so encrypt with
`--filename-override` when the plaintext lives elsewhere:

```sh
sops --encrypt --filename-override stacks/isws/myapp/secrets.enc.env \
     --input-type dotenv --output-type dotenv plain.env \
     > stacks/isws/myapp/secrets.enc.env
rm plain.env
```

Give `--filename-override` the **full repo-relative path**, not just the
basename: the creation rules match on the path, so `secrets.enc.env` alone hits
the catch-all rule and encrypts to your laptop only, producing a file the VM
cannot read.

## Rules that are easy to get wrong

**The file must be named `*.enc.env`.** `sops exec-env` has no `--input-type`
flag; it infers the dotenv format purely from the `.env` suffix. Naming it
`secrets.env.enc` or `secrets.enc` makes sops treat it as an opaque binary blob
and the whole injection path breaks.

**Never reference the encrypted file from compose `env_file:`.** Compose would
read it verbatim and hand the container
`TRAEFIK_DASHBOARD_AUTH=ENC[AES256_GCM,data:...]`. Secrets arrive through
`sops exec-env` as ambient environment, so in `docker-compose.yml` write either:

```yaml
environment:
  - DB_PASSWORD=${DB_PASSWORD:?DB_PASSWORD missing from secrets.enc.env}   # preferred
  - DB_PASSWORD                                                            # bare pass-through
```

Prefer the `${VAR:?message}` form. It documents which secrets the stack needs and
turns a missing one into a clear startup error rather than an app that comes up
and mysteriously cannot authenticate.

**Do not double the `$` in a hash.** A bcrypt or apr1 hash arriving via
`${TRAEFIK_DASHBOARD_AUTH}` needs no escaping: compose interpolation is
single-pass, so `$` inside a *value* is never re-interpolated. The `$$` rule
applies only to a `$` typed literally into `docker-compose.yml`.

Note that `stacks config` renders `$$` anyway. That is the `config` command
re-escaping its own output so the result is a valid compose file, not a corrupted
value — verified against the running container, whose label holds the single-`$`
original. Do not "fix" it.

**`stacks config` prints decrypted secrets** to your terminal and scrollback. It
warns before doing so. Do not pipe it into a file.

**dotenv cannot hold multi-line values.** Hashes, tokens, and passwords are fine.
For a TLS private key or an SSH key, use `secrets.enc.yaml` (already covered by
the creation rule) with `sops exec-file`.

**Higher-value secrets deserve a file, not an env var.** Anything in
`environment:` or `labels:` shows up in `docker inspect`. For a credential where
that matters, use compose's `secrets:` with a file mount so the app reads it from
a path instead.
