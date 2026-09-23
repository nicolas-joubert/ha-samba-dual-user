# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A Home Assistant OS add-on repository (referenced via **Settings > Add-ons > Add-on
store > Repositories**), containing a single add-on: `samba_dual_user/`. It is a
minimal, deliberately small fork of the official
[`home-assistant/addons` `samba/`](https://github.com/home-assistant/addons/tree/master/samba)
add-on, adding one feature: an optional second, read-only Samba account
(`ro_username`/`ro_password`) alongside the official add-on's single read/write
account. See `README.md` for install/usage/update instructions aimed at humans — this
file is about how the repo itself is structured and maintained.

## Why a fork instead of the existing community one

An earlier candidate (ElVit's fork) exposes raw `smb.conf` editing but carries a much
larger diff against upstream, making drift hard to audit and rebasing risky. This repo
instead keeps the diff to ~70 lines across 5 files (3 functional, 2 docs), tracked as
a literal patch file (`patches/dual-user.patch`), so rebasing onto a new upstream
release is a `git apply` plus a scripted rebranding — see `scripts/upgrade.sh` and
README's "Updating" section.

## Architecture

- `repository.yaml` — required at repo root for HAOS to recognize this as an add-on
  repository. Do not rename or remove it.
- `samba_dual_user/` — the add-on itself, a full mirror of upstream `samba/`
  (`build.yaml` pinning the base image, `CHANGELOG.md`/`DOCS.md`/`translations/` shown
  in the HA UI, icons, untouched `Dockerfile`) plus the patch and rebranding.
  `scripts/upgrade.sh` wipes and recreates this directory, so any fork-specific change
  outside the patch or the rebranding is lost on upgrade. `rootfs/` holds the
  s6-overlay services + the Go template that renders `/etc/samba/smb.conf` at
  container start.
- `scripts/upgrade.sh` — rebases `samba_dual_user/` onto a new upstream release
  (fetch, rebrand, re-apply patch, regenerate patch); see README's "Updating".
- `patches/dual-user.patch` — the entire functional diff against upstream, in a form
  that applies cleanly (verified with `git apply --check`) against a fresh checkout of
  `samba_dual_user/` laid out exactly as it is in this repo (paths in the patch are
  `samba_dual_user/...`, not `samba/...`).

## Invariants — keep these true

- **`config.yaml` must never carry an `image:` key.** Upstream's `config.yaml` has
  one (`homeassistant/{arch}-addon-samba`); it was deliberately removed so the
  Supervisor builds the image locally from this repo's `Dockerfile` instead of
  pulling home-assistant's official prebuilt image (which would silently ignore every
  change here).
- **`ro_username`/`ro_password` are schema-only, with no entry in `options:`.** That
  is what makes them genuinely optional in the HAOS config schema (`str?`/
  `password?` — a default value in `options:` would defeat that). Don't "fix" this by
  adding defaults.
- **The read-only account applies uniformly to every enabled share**, via a `read
  list` line next to each share's `valid users` line in `smb.gtpl` — there is no
  per-share opt-in for it. If that's ever needed, it's a new option (e.g.
  `ro_shares`), not a tweak to the existing lines.
- **If you touch the dual-user logic or its docs in `config.yaml`, `smb.gtpl`,
  `init-smbd/run`, `translations/en.yaml` or `DOCS.md`, regenerate
  `patches/dual-user.patch`** with
  `scripts/upgrade.sh --regen-patch` (diff against the rebranded but unpatched
  upstream copy pinned in `patches/upstream-ref`) so it keeps matching what's
  actually in the repo — the upgrade script assumes the patch file is truthful.
- `version:` in `config.yaml` follows `<upstream-samba-version>-du.<n>` (e.g.
  `12.10.0-du.1`), not upstream's own scheme — bump the `-du.<n>` suffix for any
  change that doesn't come from rebasing onto a new upstream release.

## Conventions

- English for everything written (code, comments, docs), regardless of the language a
  request comes in.
- No CI/build pipeline here (unlike the `docker/` compose stack this fork's author
  also maintains): the Supervisor builds the image on the HAOS host itself on install/
  update, there is nothing to push to a registry. The only workflow,
  `.github/workflows/upstream-check.yml`, runs daily and opens an issue when upstream
  `samba/config.yaml` has a newer `version:` than this fork's base (the part before
  `-du.<n>`); it never modifies the repo.
