#!/bin/bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/repo"
    exit 1
fi
repo="$1"

if [ ! -d "$repo/.hg" ]; then
  echo "$repo is not an hg repository"
  exit 1
fi

eden_repo="$HOME/eden"
bin="$HOME/edenscm/mononoke/bin"
base="$HOME/mononoke"
tmp=$(mktemp -d -p "$base")

# Set up environment variables that would normally be set by the test harness.
export TEST_FIXTURES="$eden_repo/eden/mononoke/tests/integration"
export MONONOKE_SERVER="$bin/mononoke"
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

set -x +u

# shellcheck disable=SC1091
. "$TEST_FIXTURES/library.sh"

export REPOID=0
export REPONAME=$(basename "$repo")
export ENABLE=true

setup_common_config
setup_mononoke_config

RUST_LOG=debug start_and_wait_for_mononoke_server

blobimport "$repo" "$repo-blob"

tail -f "$TESTTMP/mononoke.out"
