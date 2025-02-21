#!/bin/bash

set -xeuo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 path/to/git/repo"
    exit 1
fi


if [ ! -d "$1/.git" ]; then
  echo "$1 is not a git repository"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"

init_repo_env "$1"

HGRCPATH="$TESTTMP/hgrc"

cd "$TESTTMP"

set +u

ENABLED_DERIVED_DATA='["git_trees", "blame", "changeset_info",
  "deleted_manifest", "fastlog", "filenodes", "fsnodes", "unodes",
  "hgchangesets", "skeleton_manifests", "bssm"]' setup_common_config

gitimport --git-command-path=/usr/bin/git "$REPO" --derive-hg full-repo \
  2>&1 | tee "$TESTTMP/gitimport.out"

set -u

master_blake2_hash=$(grep -E 'refs/heads/main|refs/heads/master' \
  "$TESTTMP/gitimport.out" | grep -o 'Blake2([[:xdigit:]]*)' \
  | sed -E 's/^Blake2\(([[:xdigit:]]*)\)$/\1/')

mononoke_admin bookmarks set master "$master_blake2_hash"
