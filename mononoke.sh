#!/bin/bash

set -euo pipefail

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

# If this is an EdenSCM repo, then we need to convert it to a normal hg repo
# first before importing it. The .hg/reponame file is not used by vanilla hg.
repo_to_import="$repo"
if [ -f "$repo/.hg/reponame" ]; then
  converted="$(dirname "$repo")/${repo_name}-revlog"
  if [ ! -d "$converted" ]; then
     hg --cwd "$repo" debugexportrevlog "$converted"
  fi
  repo_to_import="$converted"
fi

eden_repo="$HOME/eden"
bin="$HOME/edenscm/mononoke/bin"
base="$HOME/mononoke"
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

cd "$TEST_FIXTURES"

set -x

# shellcheck disable=SC1091
. "$TEST_FIXTURES/library.sh"

export REPOID=0
export REPONAME="$repo_name"
export ENABLE=true

# The setup function will append the required settings to the repo's .hg/hgrc.
# Clear it out to start with a blank slate.
truncate -s 0 "$HGRCPATH"

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

$MONONOKE_BLOBIMPORT --repo-id $REPOID \
  --mononoke-config-path "$TESTTMP/mononoke-config" \
  "$repo_to_import/.hg" "${COMMON_ARGS[@]}"

tail -f "$TESTTMP/mononoke.out"
