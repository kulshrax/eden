#!/bin/bash

# Start the Mononoke server and update the configuration of the specified hg
# repo to use the newly-started server process. Assumes that the repository's
# data has already been imported into the server.

set -euxo pipefail

repo=$(realpath "$1")
if [ ! -d "$repo/.hg" ]; then
  echo "$repo is not an hg repository"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_repo_env "$1"

truncate -s 0 "$DAEMON_PIDS"

set +u
start_and_wait_for_mononoke_server
set -u

truncate -s 0 "$HGRCPATH"
setup_common_hg_configs
# `setup_hg_edenapi` writes to .hg/hgrc instead of using $HGRCPATH, so we
# need to cd into the repo before calling it.
cd "$REPO"
setup_hg_edenapi "$REPONAME"

cat >> "$HGRCPATH" <<EOF
[devel]
segmented-changelog-rev-compat=false
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

tail -f "$TESTTMP/mononoke.out"
