#!/bin/bash

function init_repo_env {
  if [ "$#" -lt 1 ]; then
    echo "no repo path specified" >&2
    return 1
  fi

  export REPO
  export REPONAME

  REPO=$(realpath "$1")
  if [ -f "$REPO/.hg/reponame" ]; then
    REPONAME=$(cat "$REPO/.hg/reponame")
  fi

  if [ -n "$REPONAME" ] || [ "$REPONAME" -eq "fbsource"]; then
    REPONAME=$(basename "$REPO")
  fi

  export HGRCPATH="$REPO/.hg/hgrc"
}

function init_test_env {
  local eden_repo="$HOME/eden"
  local bin="$HOME/edenscm/mononoke/bin"
  local base="$HOME/mononoke"

  if [ -z "$TESTTMP" ]; then
    TESTTMP=$(mktemp -d -p "$base")
    export TESTTMP
  else
    mkdir -p "$TESTTMP"
  fi

  # Set up environment variables that would normally be set by the test harness.
  export REPOID=0
  export ENABLE=1
  export TEST_FIXTURES="$eden_repo/eden/mononoke/tests/integration"
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
  export URLENCODE="$TESTTMP/urlencode.sh"
  export BLAME_VERSION=""
  export HG_SET_COMMITTER_EXTRA=""
  export SPARSE_PROFILES_LOCATION=""
  export DUMMYSSH="ssh"

  # Paths to various Mononoke binaries used by the tests.
  export MONONOKE_SERVER="$bin/mononoke"
  export MONONOKE_BLOBIMPORT="$bin/blobimport"
  export MONONOKE_GITIMPORT="$bin/gitimport"
  export MONONOKE_ADMIN="$bin/admin"

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
  # . "$eden_repo/eden/scm/tests/infinitepush/library.sh"

  unset HG_NO_DEFAULT_CONFIG
}

init_test_env
