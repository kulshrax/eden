#!/bin/bash

# Start the Mononoke server and update the configuration of the specified hg
# repo to use the newly-started server process. Assumes that the repository's
# data has already been imported into the server.

set -euo pipefail

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

truncate -s 0 "$DAEMON_PIDS"

set +u
start_and_wait_for_mononoke_server

tail -f "$TESTTMP/mononoke.out"
