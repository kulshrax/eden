#!/bin/bash

set -euxo pipefail

repo=$(realpath "$1")
if [ ! -d "$repo/.hg" ]; then
  echo "$repo is not an hg repository"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_mononoke_env "$1"

set +u
start_and_wait_for_mononoke_server
set -u

cat >> "$HGRCPATH" <<EOF
[paths]
default=mononoke://$(mononoke_address)/$REPONAME
[edenapi]
url=https://localhost:$MONONOKE_SOCKET/edenapi
EOF

tail -f "$TESTTMP/mononoke.out"
