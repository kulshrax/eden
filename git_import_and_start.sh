#!/bin/bash

set -xeuo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/git/repo"
    exit 1
fi

# These environment variables will be exported by the environment setup script,
# but we need the values for some preliminary steps before sourcing it.
GIT_REPO=$(realpath "$1")
GIT_REPONAME=$(basename "$GIT_REPO")
HG_REPO="$GIT_REPO-hg"

if [ ! -d "$GIT_REPO/.git" ]; then
  echo "$GIT_REPO is not a git repository"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_mononoke_env "$1"

mkdir -p "$HG_REPO/.hg"
HGRCPATH="$HG_REPO/.hg/hgrc"
touch "$HGRCPATH"

if [ -n "$TESTTMP" ]; then
  rm -rfv "$TESTTMP/*"
fi

cd "$TEST_FIXTURES"

export REPOID=1

set +u

ENABLED_DERIVED_DATA='["git_trees", "filenodes", "hgchangesets"]' \
  setup_common_config "blob_files"

gitimport "$GIT_REPO" full-repo

set -u

tail -f "$TESTTMP/mononoke.out"

