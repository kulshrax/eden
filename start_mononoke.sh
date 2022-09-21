#!/bin/bash

set -xeuo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/repo"
    exit 1
fi

# These environment variables will be exported by the environment setup script,
# but we need the values for some preliminary steps before sourcing it.
repo=$(realpath "$1")
repo_name=$(basename "$repo")

if [ ! -d "$repo/.hg" ]; then
  echo "$repo is not an hg repository"
  exit 1
fi

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
repo_to_import="$repo"
if is_eden_repo "$repo"; then
  converted="$(dirname "$repo")/$repo_name-revlog"
  if [ ! -d "$converted" ]; then
     hg --cwd "$repo" debugexportrevlog "$converted"
  fi
  repo_to_import="$converted"
fi

# shellcheck disable=SC1091
. mononoke_env.sh

init_mononoke_env "$1"

# The setup function will append the required settings to the repo's .hg/hgrc.
# Clear it out to start with a blank slate.
truncate -s 0 "$HGRCPATH"

cd "$TEST_FIXTURES"

# The functions in library.sh sometimes intentionally access unassigned
# variables, so temporarily disable unassigned variable checks.
set +u

setup_common_config

# Start the server.
RUST_LOG=debug mononoke

# This function sets a few global environment variables, so setup functions
# that access those variables can only be run after starting up the server.
wait_for_mononoke

# This function writes to the repo's .hg/hgrc, but uses a relative path so we
# need to temporarily cd into the repo.
cd "$REPO"
setup_hg_edenapi "$REPONAME"
cd -

set -u

cat >> "$HGRCPATH" <<EOF
[paths]
default=mononoke://$(mononoke_address)/$REPONAME
EOF

# By default the repo name is hardcoded as "fbsource" upon `hg init`.
echo "$REPONAME" > "$REPO/.hg/reponame"
cat >> "$HGRCPATH" <<EOF
[remotefilelog]
reponame=$REPONAME
EOF

# edenapi.url should have already been set up setup_hg_edenapi, but it sets it
# incorrectly so we need to manually override it. We can't use the address in
# `mononoke_address` because it uses 127.0.0.1, whereas the TLS certificates
# for EdenAPI use `localhost` as the common name. The variable $MONONOKE_SOCKET
# is confusingly named--it actually contains just the server port number.
cat >> "$HGRCPATH" <<EOF
# Override previously set EdenAPI URL since it shouldn't contain the repo name.
[edenapi]
url=https://localhost:$MONONOKE_SOCKET/edenapi
EOF

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
  "$repo_to_import/.hg" "${COMMON_ARGS[@]}" \
  || pkill mononoke

tail -f "$TESTTMP/mononoke.out"
