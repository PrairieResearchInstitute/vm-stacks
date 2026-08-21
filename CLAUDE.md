# Prairie Research Institute VM Configs

This repo holds docker-compose stacks for provisioning each of the PRI's virtual
machines, along with a CLI that brings a machine's stacks up when it boots.

It uses Mozilla's Secrets OPerationS (SOPS) to maintain secrets in this git repo,
which is a public repo.

## Layout

```
bin/stacks              the CLI; everything goes through it
lib/common.sh           VM + stack discovery, compose invocation, age-key probing
lib/registry.sh         anonymous container-registry tag queries for `bump`
.sops.yaml              shared, at the root; ONE creation rule per VM
stacks/_template/       shared new-stack template (skipped: leading underscore)
stacks/<vm>/vm.conf     a VM's identity: DESCRIPTION + HOSTNAMES
stacks/<vm>/<stack>/    docker-compose.yml, .env, secrets.enc.env, stack.conf
systemd/vm-stacks*      boot unit + optional weekly bump-report timer
```

VMs: `isws`, `isgs`, `odsc`. A directory under `stacks/` is a VM iff it holds a
`vm.conf`; a directory inside one is a stack iff it holds a `docker-compose.yml`.

## Rules that matter when editing this repo

**Every command acts on exactly one VM**, chosen by `--vm <name>` (accepted
anywhere in the arguments), then `$STACKS_VM`, then the machine's hostname
matched against `vm.conf`'s `HOSTNAMES`. Nothing is guessed — resolution failure
is a hard error. `require_vm` in `lib/common.sh` sets `SELECTED_VM` and scopes
`STACKS_DIR="$VMS_DIR/$SELECTED_VM"`; everything downstream reads `$STACKS_DIR`.
`updatekeys` is the deliberate exception and walks every VM.

**`systemd/vm-stacks.service` must stay machine-agnostic.** No
`Environment=STACKS_VM=`. Hostname detection is what lets one unit be installed
byte-identical on all three machines; a host rename should be a commit to a
`vm.conf`, not a change on the box.

**bash 3.2 compatibility.** This is edited on macOS and runs on Ubuntu. No
`mapfile`, no `${var,,}`, no associative arrays. Test with `/bin/bash ./bin/stacks`.

**`set -e` and `die` in command substitution.** `die` calls `exit`, which kills
the subshell before any `|| true` *inside* `$(...)` can run. To tolerate a
failing resolve, put the fallback outside: `x=$(f) || x=''`.

**`.sops.yaml` rules match on PATH, first match wins.** Per-VM rules above the
catch-all. A VM's key is a recipient of its own `stacks/<vm>/` secrets only. Any
`sops --filename-override` needs the full repo-relative path or it hits the
catch-all and produces a file no VM can read.

**`.gitignore` depth.** `!stacks/*/*/.env` — the pinned-tag files are two levels
deep now and must stay tracked. Verify with `git check-ignore -v`.
