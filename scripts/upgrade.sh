#!/usr/bin/env bash
# Rebase samba_dual_user/ onto an upstream Home Assistant samba app release.
#
#   scripts/upgrade.sh [<version-tag>]    upgrade (default: latest upstream release tag)
#   scripts/upgrade.sh --regen-patch      rewrite patches/dual-user.patch from the
#                                         current tree (after fixing .rej files by hand)
#   --force                               skip the clean-tree / already-up-to-date checks
#
# Upstream sources (since 12.11.0 the app lives in its own repository):
#   - home-assistant/app-samba, tag <version>: samba/ (Dockerfile, rootfs, config, docs)
#   - home-assistant/apps (formerly home-assistant/addons): samba/CHANGELOG.md only,
#     generated there from the release notes, cut down to <version> and older.
set -euo pipefail

APP_REPO=https://github.com/home-assistant/app-samba.git
APPS_REPO=https://github.com/home-assistant/apps.git
FORK_URL=https://github.com/nicolas-joubert/ha-samba-dual-user
ADDON=samba_dual_user

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT"
PATCH=patches/dual-user.patch
REF_FILE=patches/upstream-ref

mode=upgrade
force=0
ref=
for arg in "$@"; do
    case "$arg" in
        --regen-patch) mode=regen ;;
        --force) force=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        -*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *) ref=$arg ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

yaml_version() { sed -nE 's/^version: *"?([^"]+)"?$/\1/p' "$1"; }

# Fork identity in config.yaml; kept out of the patch on purpose.
brand() {
    local file=$1 version=$2
    sed -i -E \
        -e '/^image:/d' \
        -e "s|^version:.*|version: ${version}|" \
        -e "s|^slug:.*|slug: ${ADDON}|" \
        -e 's|^name:.*|name: Samba share (dual user)|' \
        -e "s|^url:.*|url: ${FORK_URL}|" \
        -e '/read-only account/! s|^description: *"?([^"]*)"?$|description: \1, with an extra read-only account|' \
        "$file"
    grep -q '^image:' "$file" && die "image: key still present in $file"
    for key in version slug name url description; do
        grep -q "^${key}:" "$file" || die "upstream config.yaml has no '${key}:' line, rebrand $file by hand"
    done
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Shallow-fetch <repo> at <ref> (tag, branch or commit sha) into $tmp/<dir>, print its sha.
shallow_fetch() {
    local repo=$1 ref=$2 dir=$tmp/$3
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$repo" "$ref" || die "cannot fetch $ref from $repo"
    git -C "$dir" checkout -q FETCH_HEAD
    git -C "$dir" rev-parse HEAD
}

latest_tag() {
    git ls-remote --tags --refs "$APP_REPO" \
        | sed -nE 's|.*refs/tags/([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' \
        | sort -V | tail -n1
}

# Sets upstream_version, app_sha, apps_sha. Args: version, [app sha], [apps sha]
# (shas default to the version tag / the apps repo's default branch).
fetch_upstream() {
    upstream_version=$1
    app_sha=$(shallow_fetch "$APP_REPO" "${2:-refs/tags/$1}" app)
    apps_sha=$(shallow_fetch "$APPS_REPO" "${3:-HEAD}" apps)
    [[ -f "$tmp/app/samba/config.yaml" ]] || die "no samba/ app in $APP_REPO at ${app_sha}"
    [[ -f "$tmp/apps/samba/CHANGELOG.md" ]] || die "no samba/CHANGELOG.md in $APPS_REPO at ${apps_sha}"
    grep -qx "## ${upstream_version}" "$tmp/apps/samba/CHANGELOG.md" \
        || die "samba/CHANGELOG.md in $APPS_REPO (${apps_sha:0:12}) has no '## ${upstream_version}' entry yet"
    echo "Upstream samba ${upstream_version} (app-samba ${app_sha:0:12}, apps ${apps_sha:0:12})"
}

# Mirror the whole upstream app directory; anything fork-specific must live in the patch.
copy_upstream_to() {
    local dest=$1
    rm -rf "${dest:?}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$tmp/app/samba" "$dest"
    # Changelog entries for this version and older only (upstream's release bot
    # prepends entries with CRLF line endings, normalize them).
    { printf '# Changelog\n\n'
      tr -d '\r' < "$tmp/apps/samba/CHANGELOG.md" \
          | sed -n "/^## ${upstream_version//./\\.}\$/,\$p"
    } > "$dest/CHANGELOG.md"
}

write_ref_file() {
    cat > "$REF_FILE" <<EOF
# Upstream snapshot samba_dual_user/ is based on (written by scripts/upgrade.sh).
version=${upstream_version}
app_samba=${app_sha}
apps=${apps_sha}
EOF
}

# Patch = diff between the rebranded upstream files and this repo's files.
regen_patch() {
    local version=$1 base=$tmp/base
    git init -q "$base"
    copy_upstream_to "$base/$ADDON"
    brand "$base/$ADDON/config.yaml" "$version"
    git -C "$base" add -A
    git -C "$base" -c user.name=x -c user.email=x@x commit -qm base
    rm -rf "${base:?}/$ADDON"
    cp -a "$ADDON" "$base/$ADDON"
    git -C "$base" add -A
    git -C "$base" diff --cached --no-color > "$PATCH"
    write_ref_file
    echo "Regenerated $PATCH:"
    git -C "$base" diff --cached --stat | sed 's/^/  /'
}

current_version=$(yaml_version "$ADDON/config.yaml")

if [[ $mode == regen ]]; then
    [[ -z $ref ]] || die "--regen-patch takes no ref; it uses ${REF_FILE}"
    version=; app_samba=; apps=
    # shellcheck source=/dev/null
    source "$REF_FILE" 2>/dev/null || true
    [[ -n $version && -n $app_samba && -n $apps ]] \
        || die "$REF_FILE is missing or in the old format; run a full upgrade with --force instead"
    [[ ${current_version%-du.*} == "$version" ]] \
        || die "repo is based on ${current_version%-du.*} but $REF_FILE pins ${version}"
    fetch_upstream "$version" "$app_samba" "$apps"
    regen_patch "$current_version"
    exit 0
fi

if (( ! force )) && [[ -n $(git status --porcelain -- "$ADDON" patches) ]]; then
    die "uncommitted changes in $ADDON/ or patches/, commit or stash them first (or --force)"
fi

ref=${ref:-$(latest_tag)}
[[ $ref =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "expected an upstream version tag like 12.11.0, got '${ref}'"
if (( ! force )) && [[ ${current_version%-du.*} == "$ref" ]]; then
    echo "Already based on upstream ${ref}, nothing to do (--force to redo)."
    exit 0
fi
fetch_upstream "$ref"

new_version="${upstream_version}-du.1"
copy_upstream_to "$ADDON"
brand "$ADDON/config.yaml" "$new_version"

if ! git apply --reject "$PATCH"; then
    write_ref_file
    echo
    echo "Patch did not apply cleanly. Rejected hunks:"
    find "$ADDON" -name '*.rej' | sed 's/^/  /'
    cat <<EOF

Re-apply each rejected hunk by hand (the intent: ro_username/ro_password in the schema,
the ro account in each 'valid users' plus a conditional 'read list', its creation in
init-smbd/run, and its docs in translations/en.yaml and DOCS.md), delete the .rej
files, then run:

  scripts/upgrade.sh --regen-patch
EOF
    exit 1
fi

regen_patch "$new_version"
echo
echo "Upgraded ${current_version} -> ${new_version}. Review with 'git diff', then commit and push."
