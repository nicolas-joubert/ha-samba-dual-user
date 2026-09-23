# Samba share (dual user) — Home Assistant add-on

Fork of the official [Home Assistant Samba share add-on](https://github.com/home-assistant/addons/tree/master/samba),
adding a second, **read-only** account on top of the existing read/write one — so an
automated consumer (e.g. a backup job) can never write to or delete Home
Assistant's live data, even by mistake.

Based on upstream `samba` add-on version `12.10.0`. Everything else is upstream
unchanged; the only intentional differences are the ~70 lines in
`patches/dual-user.patch` plus the rebranding in `config.yaml` (slug, name,
description, url, no `image:`).

## Why this exists

The official add-on only supports a single username/password with full read/write
access to every enabled share — no way to hand out a read-only account. This fork adds
two optional options, `ro_username` / `ro_password`: when set, that account gets
`read list` on every enabled share, so it is read-only by construction (Samba enforces
it), not by convention.

## Install

1. In Home Assistant: **Settings > Apps > Install app > ⋮ > Repositories** (formerly
   *Settings > Add-ons > Add-on store*), add this repository's URL:
   `https://github.com/nicolas-joubert/ha-samba-dual-user`.
2. Install **"Samba share (dual user)"**.
3. Configure both accounts in the add-on's *Configuration* tab:
   - `username` / `password`: normal read/write account (same as the official add-on).
   - `ro_username` / `ro_password`: read-only account, for anything automated. Leave
     both empty to behave exactly like the official add-on.
4. Start the add-on.

## Updating when the official add-on releases a new version

This fork tracks upstream closely on purpose, via one small patch file
(`patches/dual-user.patch`, ~70 lines across 5 files: `config.yaml`,
`rootfs/usr/share/tempio/smb.gtpl`, `rootfs/etc/s6-overlay/s6-rc.d/init-smbd/run`,
plus the option docs in `translations/en.yaml` and `DOCS.md`) — small enough to read in full and re-apply by hand if it ever fails to apply cleanly.

A daily GitHub Action (`.github/workflows/upstream-check.yml`) opens an issue in this
repository when upstream publishes a new version, so there is no need to watch
upstream by hand.

```bash
scripts/upgrade.sh            # or: scripts/upgrade.sh <upstream-commit-sha>
git diff                      # review before trusting it
git add -A && git commit -m "Rebase onto upstream samba <version>"
git push
```

The script fetches upstream `samba/`, replaces the whole `samba_dual_user/` directory
with it (so `build.yaml`, `CHANGELOG.md`, `DOCS.md`, translations and icons stay
identical to the official add-on), redoes the fork's rebranding in
`config.yaml` (slug, name, description, url, no `image:`, version
`<new-upstream-version>-du.1`), re-applies `patches/dual-user.patch`, then regenerates
that patch (and records the upstream commit in `patches/upstream-ref`) so it stays
truthful. It refuses to run on uncommitted changes and does nothing if already based
on the latest upstream version (`--force` overrides both).

If the patch fails to apply (upstream restructured one of those files), the script
leaves `.rej` files next to the affected files. Re-apply their intent by hand — the
patch only ever: adds `ro_username`/`ro_password` to the config schema, adds the
read-only account to each share's `valid users` plus a conditional `read list` line,
creates that account in `init-smbd/run`, and documents both options in
`translations/en.yaml` and `DOCS.md` — delete the `.rej` files, then run the `scripts/upgrade.sh --regen-patch <sha>` command
the script printed.

## What this fork deliberately does NOT do

- No per-share ro/rw split: the read-only account sees the same shares as the
  read/write one (`enabled_shares`), just read-only on all of them. Restricting it to
  specific shares (e.g. `backup` only) would need an extra `ro_shares` option, not
  implemented here to keep the patch minimal.
- `Dockerfile` is untouched — no new dependency was needed; `adduser`, `addgroup` and
  `smbpasswd` were already used by the official add-on for the primary account.
