# Bootstrapping a VM

Ubuntu 22.04 or newer. Everything below runs as root or under `sudo`.
Versions are dated so a rebuild years from now is reproducible.

Throughout, `<vm>` is the machine's short name and its directory under
`stacks/` — `isws`, `isgs`, or `odsc`.

**Adding a VM that does not exist in the repo yet?** Do [§0](#0-declare-the-vm-repo-side)
from your laptop first. Rebuilding one that already has a directory? Skip to §1.

## 0. Declare the VM (repo side)

From your laptop, one commit:

```sh
mkdir stacks/<vm>
$EDITOR stacks/<vm>/vm.conf
```

```sh
DESCRIPTION="What this machine is for"
HOSTNAMES="<vm> <vm>.prairie.illinois.edu"
```

`HOSTNAMES` is what lets one systemd unit work on every machine — `bin/stacks`
matches the running host against it to decide which VM it is. Confirm the values
against `hostname -f` on the machine itself in [§4](#4-confirm-the-vm-resolves).

Then add a `creation_rules` entry for the VM in [`.sops.yaml`](../.sops.yaml),
above the catch-all, with your laptop key only for now:

```yaml
  - path_regex: stacks/<vm>/.*secrets\.enc\.(env|yaml|json)$
    age: >-
      age1p0ucq5gllknvjdhnya06xjz8fl67nua5ddt7g5l88tcetv5e03ys3f25ex
```

The machine's own key gets added in [§5](#5-give-the-vm-an-age-key), once it
exists. Commit and push.

## 1. Docker Engine + Compose v2

Use Docker's own apt repository, **not** Ubuntu's `docker.io` package — the
latter lags and does not ship the Compose v2 plugin.

```sh
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io \
                   docker-buildx-plugin docker-compose-plugin
```

Verify — this exact command must work, because `bin/stacks` requires it:

```sh
docker compose version        # must print v2.x or later
```

If only `docker-compose version` (with a hyphen) works, you have Compose v1 and
nothing in this repo will run.

## 2. sops and age

`age` is in Ubuntu universe. `sops` is **not** in the Ubuntu repositories —
install the official `.deb`.

```sh
apt-get install -y age jq curl

SOPS_VERSION=3.13.3     # current as of 2026-08
ARCH=$(dpkg --print-architecture)
curl -fsSLO "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops_${SOPS_VERSION}_${ARCH}.deb"
sha256sum "sops_${SOPS_VERSION}_${ARCH}.deb"   # compare against the release page
apt-get install -y "./sops_${SOPS_VERSION}_${ARCH}.deb"
rm "sops_${SOPS_VERSION}_${ARCH}.deb"

sops --version && age --version
```

## 3. Clone the repo, sparse

This one repo serves every PRI VM, but a machine has no business having the other
machines' compose files sitting in `/opt`. Use a **sparse checkout** so the
working tree holds only the shared tooling and this VM's directory. The clone is
still a full clone — same history, same `git pull`, same commits — only the files
written to disk are narrowed.

The systemd unit hardcodes `/opt/vm-stacks`. Clone there, or edit
`systemd/vm-stacks.service` before installing.

```sh
git clone --no-checkout \
  https://github.com/PrairieResearchInstitute/vm-stacks.git /opt/vm-stacks
cd /opt/vm-stacks
git sparse-checkout set --cone bin lib systemd docs "stacks/<vm>"
git checkout main

chown -R root:root /opt/vm-stacks
chmod 755 /opt/vm-stacks
```

`--no-checkout` first, then narrow, then check out: cloning normally would write
every VM's files to disk and then delete them again. Cone mode needs git ≥ 2.27;
Ubuntu 22.04 ships 2.34, so this is only a concern on something older.

**List `bin lib systemd docs` explicitly.** In cone mode a directory is either in
the cone or absent, and repo-root *files* (`.sops.yaml`, `README.md`) come along
free but sibling *directories* do not. `git sparse-checkout set --cone stacks/<vm>`
on its own leaves you without `bin/stacks` or `lib/`, and nothing works. `docs/`
is in the list because troubleshooting docs are worth having on the box at 03:00;
drop it if you disagree. `stacks/_template/` is deliberately left out — new stacks
are created from a laptop.

Check what you got:

```sh
git sparse-checkout list        # bin docs lib stacks/<vm> systemd
ls stacks                       # <vm>, and nothing else
```

A later `git pull` keeps the rules and updates only in-cone files, so this is a
one-time setup. Two consequences worth knowing:

- `stacks vms` on the VM lists only that VM, because it discovers VMs by looking
  for `stacks/*/vm.conf` on disk. Hostname detection is unaffected — the VM it
  needs to match is the one that is there.
- `stacks updatekeys` on the VM would only re-key that VM's secrets. Run it from
  a laptop, which is where it belongs anyway (see §5).

To widen later — a second VM on one machine, or just to look around:

```sh
git sparse-checkout set --cone bin lib systemd docs stacks/isws stacks/isgs
git sparse-checkout disable      # back to a full working tree
```

**On your laptop, do not do any of this.** A full clone is what lets
`stacks updatekeys` re-key every VM in one pass and `stacks/_template` be copied
into a new stack.

## 4. Confirm the VM resolves

This is the step that replaces having a per-machine config file, so it is worth
doing before anything depends on it:

```sh
hostname -s
hostname -f
/opt/vm-stacks/bin/stacks vms
```

The `*` in the `vms` output must be on the row you expect.

**One row, not starred**: the machine's names are not in that `vm.conf`. Add them
to its `HOSTNAMES` from your laptop, push, and `git pull` here. Fixing it in the
repo rather than by setting `STACKS_VM` on the box means a host rename is one
reviewable commit.

**No rows at all**, or `stacks status` reporting `no VM directories under ...`:
the sparse checkout named a VM that does not exist — a typo in §3, most likely.
Check with `git sparse-checkout list` and `ls stacks`, then re-run the
`sparse-checkout set` with the right name.

## 5. Give the VM an age key

**Rebuilding an existing VM?** Check first:

```sh
ls -l /data/secrets/age.key
```

`/data` is a persistent volume, which is exactly why the key lives there. If
that file is already present the VM is still a recipient — skip the rest of this
section entirely and go to step 6. Do **not** regenerate; a new keypair would
mean re-keying every secrets file for nothing.

Otherwise, generate a keypair **on the VM** so the private half never travels:

```sh
install -d -m 0700 /data/secrets
age-keygen -o /data/secrets/age.key
chmod 600 /data/secrets/age.key
grep 'public key' /data/secrets/age.key
```

Take that public key, add it to **this VM's rule** in `.sops.yaml` from your
laptop, re-key, and push:

```sh
# on your laptop
$EDITOR .sops.yaml     # ADD the age1... key to the stacks/<vm>/ rule -- do not replace
stacks updatekeys      # re-encrypts every VM's secrets against the current rules
git commit -am 'sops: add <vm> as a recipient' && git push
```

Add it to that VM's rule and no other: a machine has no business decrypting
another machine's secrets. `stacks updatekeys` walks every VM on purpose, because
`.sops.yaml` is shared and re-keying half the repo is how you end up with a file
nobody can read.

Then `git pull` on the VM. Until this is done the VM cannot decrypt anything and
`stacks up` will fail with a decryption error — that is expected, not a bug.

## 6. Firewall

```sh
ufw allow 80/tcp
ufw allow 443/tcp
```

Port 80 must stay open even though everything redirects to HTTPS: it is where
the ACME HTTP challenge and the redirect itself are served.

## 7. Install the boot unit

```sh
/opt/vm-stacks/bin/stacks install     # copies + enables vm-stacks.service
systemctl start vm-stacks
systemctl status vm-stacks
journalctl -u vm-stacks -f
```

`install` resolves the VM first and prints which one it detected, so a `HOSTNAMES`
mistake surfaces here rather than at the next reboot. The unit itself carries no
VM name.

## 8. Give the VM a traefik stack

A brand-new VM has no stacks. Every VM needs the edge proxy first; copy an
existing one rather than the bare template, then change the hostnames. This is
laptop work — the VM's sparse checkout cannot see `stacks/isws/` to copy from:

```sh
# on your laptop, in a full clone
cp -r stacks/isws/traefik stacks/<vm>/traefik
rm -f stacks/<vm>/traefik/secrets.enc.env    # do NOT reuse another VM's secrets
$EDITOR stacks/<vm>/traefik/.env             # TRAEFIK_DASHBOARD_HOST, ACME email
stacks --vm <vm> edit-secrets traefik        # a fresh TRAEFIK_DASHBOARD_AUTH
```

Deleting the copied `secrets.enc.env` is not optional: it is encrypted to the
source VM's recipients, so it would neither decrypt on the new machine nor be
appropriate to share if it did.

Then add applications — [adding-a-stack.md](adding-a-stack.md).

## 9. Verify

```sh
cd /opt/vm-stacks
./bin/stacks status                 # every enabled stack running
curl -sI http://localhost/          # 308 redirect to https
```

## 10. Certificates: staging → production

A new VM's traefik `.env` should point at the **Let's Encrypt staging** CA, which
issues untrusted certificates but has generous rate limits. Leave it there until
DNS resolves to this VM and ports 80/443 are reachable from the internet, then
switch:

```sh
$EDITOR stacks/<vm>/traefik/.env    # TRAEFIK_ACME_CASERVER -> the prod URL
./bin/stacks up traefik
```

Switching early risks burning Let's Encrypt's duplicate-certificate limit
(5 per week) while you debug DNS, which then blocks you for days.

Because staging and production certificates share one `acme.json`, clear the old
staging certs when you cut over:

```sh
docker volume rm traefik_acme       # after `stacks down traefik`
```

## Optional: weekly update reports

```sh
cp /opt/vm-stacks/systemd/vm-stacks-bump.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now vm-stacks-bump.timer
```

Reports available image updates for this VM to the journal every Monday. It is a
dry run and never changes anything — see [updating-images.md](updating-images.md)
for why.

## New-VM checklist

The short form of everything above, since it gets done once per machine:

1. `stacks/<vm>/vm.conf` with `DESCRIPTION` and `HOSTNAMES` (§0)
2. a scoped `creation_rules` entry in `.sops.yaml`, laptop key only (§0)
3. Docker, sops, age; sparse clone to `/opt/vm-stacks` (§1–3)
4. `stacks vms` stars the right row (§4)
5. `age-keygen` on the VM; add the public key to that VM's rule;
   `stacks updatekeys`; commit; `git pull` on the VM (§5)
6. `stacks install` && `systemctl start vm-stacks` (§7)
7. copy a `traefik` stack in, with fresh secrets (§8)
8. staging → production certificates once DNS is live (§10)
