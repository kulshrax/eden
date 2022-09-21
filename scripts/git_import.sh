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

init_mononoke_env "$1"

if [ -n "$TESTTMP" ] && [ -n "$(ls -A "$TESTTMP")" ]; then
  rm -rfv "${TESTTMP:?}"/*
fi

cd "$TESTTMP"

set +u

HGRCPATH="$TESTTMP/hgrc" \
  ENABLED_DERIVED_DATA='["git_trees", "filenodes", "hgchangesets"]' \
  setup_common_config

gitimport --git-command-path=/usr/bin/git "$REPO" --derive-hg full-repo \
  2>&1 | tee "$TESTTMP/gitimport.out"

set -u

master_blake2_hash=$(grep -o 'Blake2([[:xdigit:]]*)' "$TESTTMP/gitimport.out"\
  | sed -E 's/^Blake2\(([[:xdigit:]]*)\)$/\1/')

mononoke_admin bookmarks set master "$master_blake2_hash"
