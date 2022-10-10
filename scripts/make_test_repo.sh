#!/bin/bash

set -euxo pipefail

if [[ "$#" -lt 2 ]]; then
  echo "usage: $0 SRC_REPO DST_REPO" >&2
  exit 1
fi

src_repo=$(realpath "$1")
dst_repo=$(realpath "$2")

echo "Cleaning $src_repo"
cd "$src_repo"
/usr/bin/hg update -C .
/usr/bin/hg purge

alias hg=sl

cd "$src_repo"
echo "Finding files and directories"
files=$(find . -maxdepth 1 -type f | sed 's/^\.\///'| sort)
dirs=$(find . -maxdepth 1 -type d | sed 's/^\.\///' | sed '/^\.$/d;/^\.hg$/d'| sort)

cd "$dst_repo"

echo "Adding top-level files"
for file in $files; do
  mv "$src_repo/$file" .
done

# These tend to cause issues with adding and removing directories.
rm -f .hgignore .gitignore

hg addremove
hg commit -m "Added top level files"
hg push --to master

echo "Adding directories"
for dir in $dirs; do
    echo "Moving $dir"
    mv "$src_repo/$dir" .
    hg add "$dir"
    hg commit -m "Added directory $dir"
    echo "Committed contents of $dir"
    hg push --to master
    echo "Pushed $dir"
done

echo "Removing directories"
for dir in $dirs; do
    echo "Removing $dir"
    hg rm "$dir"
    hg commit -m "Removed directory $dir"
    echo "Removed $dir"
    hg push --to master
    echo "Pushed removal of $dir"
done

