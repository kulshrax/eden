#!/bin/bash

# Configure the given EdenSCM repo to talk to the running Mononoke server.

set -euo pipefail

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_repo_env "${1:-.}"

if [ ! -d "$REPO/.hg" ]; then
  echo "$REPO is not an hg repository"
  exit 1
fi

server_addr_file="$TESTTMP/mononoke_server_addr.txt"
if [ ! -f "$server_addr_file" ]; then
  echo "No running Mononoke server found" >&2
  exit 1
fi

server_addr=$(cat "$server_addr_file")
edenapi_addr=${server_addr//127\.0\.0\.1/localhost}

truncate -s 0 "$HGRCPATH"
setup_common_hg_configs
# `setup_hg_edenapi` writes to .hg/hgrc instead of using $HGRCPATH, so we
# need to cd into the repo before calling it.
cd "$REPO"
setup_hg_edenapi "$REPONAME"

cat >> "$HGRCPATH" <<EOF
[remotefilelog]
reponame=$REPONAME

[paths]
default=mononoke://$server_addr/$REPONAME

[edenapi]
url=https://$edenapi_addr/edenapi

[devel]
segmented-changelog-rev-compat=false

[extensions]
commitcloud=
infinitepush=

[commitcloud]
servicetype=local
servicelocation=$TESTTMP
pullcreatemarkers=

[infinitepush]
branchpattern=re:scratch/.*
EOF

echo "Updated $HGRCPATH to talk to server listening at $server_addr"
