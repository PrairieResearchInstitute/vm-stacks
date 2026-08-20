# Bootstrapping a fresh VM

Ubuntu 22.04 or newer. Everything below runs as root or under `sudo`.
Versions are dated so a rebuild years from now is reproducible.

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

## 3. Clone the repo

The systemd unit hardcodes `/opt/isws-vm`. Clone there, or edit
`systemd/isws-stacks.service` before installing.

```sh
git clone https://github.com/<org>/isws-vm.git /opt/isws-vm
chown -R root:root /opt/isws-vm
chmod 755 /opt/isws-vm
```

## 4. Give the VM an age key

**Rebuilding an existing VM?** Check first:

```sh
ls -l /data/secrets/age.key
```

`/data` is a persistent volume, which is exactly why the key lives there. If
that file is already present the VM is still a recipient — skip the rest of this
section entirely and go to step 5. Do **not** regenerate; a new keypair would
mean re-keying every secrets file for nothing.

Otherwise, generate a keypair **on the VM** so the private half never travels:

```sh
install -d -m 0700 /data/secrets
age-keygen -o /data/secrets/age.key
chmod 600 /data/secrets/age.key
grep 'public key' /data/secrets/age.key
```

Take that public key, add it to `.sops.yaml` from your laptop, re-key the
existing secrets, and push:

```sh
# on your laptop
$EDITOR .sops.yaml     # ADD the VM's age1... key to the list -- do not replace
stacks updatekeys      # re-encrypt to both recipients
git commit -am 'sops: add isws-vm as a recipient' && git push
```

Then `git pull` on the VM. Until this is done the VM cannot decrypt anything and
`stacks up` will fail with a decryption error — that is expected, not a bug.

## 5. Firewall

```sh
ufw allow 80/tcp
ufw allow 443/tcp
```

Port 80 must stay open even though everything redirects to HTTPS: it is where
the ACME HTTP challenge and the redirect itself are served.

## 6. Install the boot unit

```sh
/opt/isws-vm/bin/stacks install     # copies + enables isws-stacks.service
systemctl start isws-stacks
systemctl status isws-stacks
journalctl -u isws-stacks -f
```

## 7. Verify

```sh
cd /opt/isws-vm
./bin/stacks status                 # every enabled stack running
curl -sI http://localhost/          # 308 redirect to https
```

## 8. Certificates: staging → production

`stacks/traefik/.env` ships pointing at the **Let's Encrypt staging** CA, which
issues untrusted certificates but has generous rate limits. Leave it there until
DNS resolves to this VM and ports 80/443 are reachable from the internet, then
switch:

```sh
$EDITOR stacks/traefik/.env         # TRAEFIK_ACME_CASERVER -> the prod URL
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
cp /opt/isws-vm/systemd/isws-stacks-bump.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now isws-stacks-bump.timer
```

Reports available image updates to the journal every Monday. It is a dry run and
never changes anything — see [updating-images.md](updating-images.md) for why.
