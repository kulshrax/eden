#!/bin/bash

set -xeuo pipefail

if [ "$#" -lt 1 ]; then
    echo "usage: $0 REPO_NAME DEST_PATH"
    exit 1
fi

repo="$1"
path="${2:-"$(pwd)/$repo"}"

if [ -d "$path" ]; then
  echo "Destination directory already exists: $path"
  exit 1
fi

script_dir=$(dirname "$(realpath "$0")")
# shellcheck disable=SC1091
. "$script_dir/mononoke_env.sh"


server_addr_file="$TESTTMP/mononoke_server_addr.txt"
if [ ! -f "$server_addr_file" ]; then
  echo "No running Mononoke server found" >&2
  exit 1
fi

server_addr=$(cat "$server_addr_file")
edenapi_addr=${server_addr//127\.0\.0\.1/localhost}

cert="$TEST_CERTDIR/client0.crt"
key="$TEST_CERTDIR/client0.key"
ca="$TEST_CERTDIR/root-ca.crt"

hg clone "mononoke://$server_addr/$repo" "$path" --shallow \
  --config remotefilelog.reponame="$repo" \
  --config paths.default="mononoke://$server_addr/$repo" \
  --config edenapi.url="https://$edenapi_addr/edenapi" \
  --config edenapi.enable=true \
  --config remotefilelog.http=true \
  --config auth.mononoke.prefix="mononoke://*" \
  --config auth.mononoke.cert="$cert" \
  --config auth.mononoke.key="$key" \
  --config auth.mononoke.cn=localhost \
  --config auth.edenapi.prefix=localhost \
  --config auth.edenapi.cert="$cert" \
  --config auth.edenapi.key="$key" \
  --config auth.edenapi.cacerts="$ca" \
  --config web.cacerts="$ca"

"$script_dir/update_hgrc.sh" "$path"
