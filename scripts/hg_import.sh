#!/bin/bash

set -xeuo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/repo"
    exit 1
fi

if [ ! -d "$1/.hg" ]; then
  echo "$1 is not an hg repository"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_repo_env "$1"

cd "$TESTTMP"

truncate -s 0 "$HGRCPATH"

# The functions in library.sh sometimes intentionally access unassigned
# variables, so temporarily disable unassigned variable checks.
set +u

setup_common_config

# XXX: This is a hacky way of detecting whether a repo was created with stock
# Mercurial or with EdenSCM. It happens to work because EdenSCM does not have
# a `share-safe` feature (since it was forked at hg version 4.2, prior to this
# feature's introduction), whereas it appears that most modern Mercurial repos
# require this feature.
function is_eden_repo {
   ! grep 'share-safe' < "$1/.hg/requires" 2>&1 > /dev/null
}

# If this is an EdenSCM repo, then we need to convert it to a normal hg repo
# first before importing it. We need to do this step BEFORE sourcing the test
# environment setup script because it configures hg in such a way that makes
# `hg debugexportrevlog` crash.
repo_to_import="$REPO"
if is_eden_repo "$REPO"; then
  converted="$(dirname "$REPO")/$REPONAME-revlog"
  if [ ! -d "$converted" ]; then
     hg --cwd "$REPO" debugexportrevlog "$converted"
  fi
  repo_to_import="$converted"
fi

# Ensure that the "master" bookmark exists prior to import. This is assumed to
# be the name of the main branch and is hardcoded everywhere, so it can't be
# easily changed.
/usr/bin/hg --cwd "$repo_to_import" bookmarks -f -r tip master

mv "$repo_to_import/.hg/requires" "$repo_to_import/.hg/requires.bak"
cat > "$repo_to_import/.hg/requires" <<EOF
dotencode
fncache
store
EOF

$MONONOKE_BLOBIMPORT --repo-id "$REPOID" \
  --mononoke-config-path "$TESTTMP/mononoke-config" \
  "$repo_to_import/.hg" "${COMMON_ARGS[@]}"
