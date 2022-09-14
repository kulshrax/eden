#!/bin/bash

set -xeou pipefail

repo="$HOME/eden"
bin="$HOME/edenscm/mononoke/bin"
base="$HOME/mononoke"
tmp=$(mktemp -d -p "$base")

# Set up environment variables that would normally be set by the test harness.
export TEST_FIXTURES="$repo/eden/mononoke/tests/integration"
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
export HGRCPATH="$TESTTMP/.hgrc"
export DUMMYSSH=""

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

# shellcheck disable=SC1091
. "$TEST_FIXTURES/library.sh"

setup_common_config
REPOID=1 REPONAME=testrepo ENABLED=true setup_mononoke_config
RUST_LOG=debug mononoke

tail -f "$TESTTMP/mononoke.out"
