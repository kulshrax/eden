#!/bin/bash

set -xeuo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/repo"
    exit 1
fi

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
# first before importing it.
repo_to_import="$repo"
if is_eden_repo "$repo"; then
  converted="$(dirname "$repo")/${repo_name}-revlog"
  if [ ! -d "$converted" ]; then
     hg --cwd "$repo" debugexportrevlog "$converted"
  fi
  repo_to_import="$converted"
fi

eden_repo="$HOME/eden"
bin="$HOME/edenscm/mononoke/bin"
base="$HOME/mononoke"

rm -rf $base/tmp.*
tmp=$(mktemp -d -p "$base")

# Set up environment variables that would normally be set by the test harness.
export TEST_FIXTURES="$eden_repo/eden/mononoke/tests/integration"
export MONONOKE_SERVER="$bin/mononoke"
export MONONOKE_BLOBIMPORT="$bin/blobimport"
export TESTTMP="$tmp"
export TEST_CERTS="$TEST_FIXTURES/certs"
export FB_TEST_FIXTURES=""
export DB_SHARD_NAME=""
export HAS_FB=""
export SKIP_CROSS_REPO_CONFIG="1"
export LOCALIP="127.0.0.1"
export DAEMON_PIDS="$TESTTMP/pids"
export SCUBA_CENSORED_LOGGING_PATH=""
export DISABLE_HTTP_CONTROL_API=""
export ADDITIONAL_MONONOKE_COMMON_CONFIG=""
export URLENCODE="$tmp/urlencode.sh"
export BLAME_VERSION=""
export HG_SET_COMMITTER_EXTRA=""
export SPARSE_PROFILES_LOCATION=""
export HGRCPATH="$repo/.hg/hgrc"
export DUMMYSSH="ssh"

# The setup code in library.sh expects that $URLENCODE will contain a path to a
# program with an `encode` subcommand that URL-encodes its argument. Since it
# is always called with the `encode` subcommand, we can simply ignore the first
# argument and use `jq` to encode the second.
cat > "$URLENCODE" <<EOF
#!/bin/bash
echo \$2 | jq -Rr @uri
EOF
chmod +x "$URLENCODE"

export REPOID=0
export REPONAME="$repo_name"
export ENABLE=true

# The setup function will append the required settings to the repo's .hg/hgrc.
# Clear it out to start with a blank slate.
truncate -s 0 "$HGRCPATH"

cd "$TEST_FIXTURES"

# The functions in library.sh sometimes intentionally access unassigned
# variables, so temporarily disable unassigned variable checks.
set +u

# shellcheck disable=SC1091
. "$TEST_FIXTURES/library.sh"

setup_common_config

# Start the server.
RUST_LOG=debug mononoke

# This function sets a few global environment variables, so setup functions
# that access those variables can only be run after starting up the server.
wait_for_mononoke

# This function writes to the repo's .hg/hgrc, but uses a relative path so we
# need to temporarily cd into the repo.
cd "$repo"
setup_hg_edenapi "$repo_name"
cd -

set -u

cat >> "$HGRCPATH" <<EOF
[paths]
default=mononoke://$(mononoke_address)/$repo_name
EOF

# By default the repo name is hardcoded as "fbsource" upon `hg init`.
echo "$repo_name" > "$repo/.hg/reponame"
cat >> "$HGRCPATH" <<EOF
[remotefilelog]
reponame=$repo_name
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

$MONONOKE_BLOBIMPORT --repo-id $REPOID \
  --mononoke-config-path "$TESTTMP/mononoke-config" \
  "$repo_to_import/.hg" "${COMMON_ARGS[@]}" \
  || pkill mononoke

tail -f "$TESTTMP/mononoke.out"
