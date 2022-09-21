#!/bin/bash

function init_mononoke_env {
  if [[ "$#" -lt 1 ]]; then
    echo "no repo path specified" >&2
    return 1
  fi

  local eden_repo="$HOME/eden"
  local bin="$HOME/edenscm/mononoke/bin"
  local base="$HOME/mononoke"

  local tmp
  #tmp=$(mktemp -d -p "$base")
  tmp="$base"

  # Set up environment variables that would normally be set by the test harness.
  export REPO
  REPO=$(realpath "$1")
  export REPONAME
  REPONAME=$(basename "$REPO")
  export REPOID=0
  export ENABLE=1
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
  export HGRCPATH="$REPO/.hg/hgrc"
  export DUMMYSSH="ssh"

  # The setup code in library.sh expects that $URLENCODE will contain a path to
  # a program with an `encode` subcommand that URL-encodes its argument. Since
  # it is always called with the `encode` subcommand, we can simply ignore the
  # first argument and use `jq` to encode the second.
  cat > "$URLENCODE" <<EOF
#!/bin/bash
echo \$2 | jq -Rr @uri
EOF
  chmod +x "$URLENCODE"

  set +u
  # shellcheck disable=SC1091
  . "$TEST_FIXTURES/library.sh"
  set -u
}
