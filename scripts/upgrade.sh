#!/usr/bin/env bash
# Rebase samba_dual_user/ onto an upstream home-assistant/addons samba/ release.
#
#   scripts/upgrade.sh [<upstream-ref>]   upgrade (default ref: master)
#   scripts/upgrade.sh --regen-patch      rewrite patches/dual-user.patch from the
#                                         current tree (after fixing .rej files by hand)
#   --force                               skip the clean-tree / already-up-to-date checks
set -euo pipefail

UPSTREAM_REPO=https://github.com/home-assistant/addons.git
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
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
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

fetch_upstream() {
    git init -q "$tmp/upstream"
    git -C "$tmp/upstream" fetch -q --depth 1 "$UPSTREAM_REPO" "$1"
    git -C "$tmp/upstream" checkout -q FETCH_HEAD
    [[ -f "$tmp/upstream/samba/config.yaml" ]] || die "no samba/ add-on at upstream ref $1"
    upstream_sha=$(git -C "$tmp/upstream" rev-parse HEAD)
    upstream_version=$(yaml_version "$tmp/upstream/samba/config.yaml")
    echo "Upstream samba ${upstream_version} (${upstream_sha:0:12})"
}

# Mirror the whole upstream add-on directory; anything fork-specific must live in the patch.
copy_upstream_to() {
    local dest=$1
    rm -rf "${dest:?}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$tmp/upstream/samba" "$dest"
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
    echo "$upstream_sha" > "$REF_FILE"
    echo "Regenerated $PATCH:"
    git -C "$base" diff --cached --stat | sed 's/^/  /'
}

current_version=$(yaml_version "$ADDON/config.yaml")

if [[ $mode == regen ]]; then
    ref=${ref:-$(cat "$REF_FILE" 2>/dev/null || echo master)}
    fetch_upstream "$ref"
    [[ ${current_version%-du.*} == "$upstream_version" ]] \
        || die "repo is based on ${current_version%-du.*} but ref $ref is ${upstream_version}; pass the matching ref"
    regen_patch "$current_version"
    exit 0
fi

if (( ! force )) && [[ -n $(git status --porcelain -- "$ADDON" patches) ]]; then
    die "uncommitted changes in $ADDON/ or patches/, commit or stash them first (or --force)"
fi

fetch_upstream "${ref:-master}"
if (( ! force )) && [[ ${current_version%-du.*} == "$upstream_version" ]]; then
    echo "Already based on upstream ${upstream_version}, nothing to do (--force to redo)."
    exit 0
fi

new_version="${upstream_version}-du.1"
copy_upstream_to "$ADDON"
brand "$ADDON/config.yaml" "$new_version"

if ! git apply --reject "$PATCH"; then
    echo
    echo "Patch did not apply cleanly. Rejected hunks:"
    find "$ADDON" -name '*.rej' | sed 's/^/  /'
    cat <<EOF

Re-apply each rejected hunk by hand (the intent: ro_username/ro_password in the schema,
the ro account in each 'valid users' plus a conditional 'read list', its creation in
init-smbd/run, and its docs in translations/en.yaml and DOCS.md), delete the .rej
files, then run:

  scripts/upgrade.sh --regen-patch ${upstream_sha}
EOF
    exit 1
fi

regen_patch "$new_version"
echo
echo "Upgraded ${current_version} -> ${new_version}. Review with 'git diff', then commit and push."
