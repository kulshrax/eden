#!/bin/bash

set -euo pipefail

if [[ "$#" -lt 1 ]]; then
  echo "usage: $0 SRC_REPO [DST_REPO]" >&2
  exit 1
fi

src_repo="$1"
dst_repo="${2:-$1-eden}"
tmp=$(mktemp -d)

echo "Cleaning $src_repo"
cd "$src_repo"
/usr/bin/hg update -C .
/usr/bin/hg purge

echo "Finding files and directories"
files=$(find . -maxdepth 1 -type f | sed 's/^\.\///'| sort)
dirs=$(find . -maxdepth 1 -type d | sed 's/^\.\///' | sed '/^\.$/d;/^\.hg$/d'| sort)

echo "Creating $dst_repo"
if [ -d "$dst_repo" ]; then
  echo "$dst_repo already exists; moving aside to $tmp"
  mv "$dst_repo" "$tmp"
fi
hg init "$dst_repo"
cd "$dst_repo"

echo "Adding top-level files"
for file in $files; do
  mv "$src_repo/$file" .
done

# Move these aside.
mv .hgignore .gitignore "$tmp"

hg addremove
hg commit -m "Added top level files"
echo "Committed files"

echo "Adding directories"
for dir in $dirs; do
    echo "Moving $dir"
    mv "$src_repo/$dir" .
    hg add "$dir"
    hg commit -m "Added directory $dir"
    echo "Committed contents of $dir"
done

echo "Removing directories"
for dir in $dirs; do
    echo "Removing $dir"
    hg rm "$dir"
    hg commit -m "Removed directory $dir"
    echo "Removed $dir"
done
