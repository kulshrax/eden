#!/bin/bash

set -xeuo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/git/repo"
    exit 1
fi

# These environment variables will be exported by the environment setup script,
# but we need the values for some preliminary steps before sourcing it.
REPO=$(realpath "$1")
REPONAME=$(basename "$REPO")

if [ ! -d "$REPO/.git" ]; then
  echo "$REPO is not a git repository"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_mononoke_env "$1"

cd "$TEST_FIXTURES"

set +u

ENABLED_DERIVED_DATA='["git_trees", "filenodes", "hgchangesets"]' \
  setup_common_config "blob_files"

gitimport "$REPO"

set -u

tail -f "$TESTTMP/mononoke.out"

