#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Please specify an installation directory"
    exit 1
fi

prefix=$(realpath "$1")
mkdir -p "$prefix"
cd "$prefix"

status="$prefix/build_status.log"
echo "Installing under: $prefix" >> "$status"

repo_path=$(dirname "$0")
getdeps_py="build/fbcode_builder/getdeps.py"

# If we're not running the script from within the eden repo itself, check if
# there's a copy of the repo in the installation directory, otherwise clone it.
if [ ! -f "$repo_path/$getdeps_py" ]; then
  repo="source"
  repo_url="https://github.com/kulshrax/eden.git"
  repo_path="$prefix/$repo"

  if [ ! -d "$repo_path" ]; then
    git clone "$repo_url" "$repo_path"
    echo "Cloned repo to: $repo_path" >> "$status"
  fi
fi

echo "Using repo at: $repo_path" >> "$status"

getdeps="python3 $repo_path/$getdeps_py"

for project in "eden_scm" "eden" "mononoke";
do
  if [ ! -d "$prefix/$project/bin" ]; then
    $getdeps build "$project" --install-dir="$prefix/$project"
    echo "Built project $project" >> "$status"
  fi

  $getdeps fixup-dyn-deps "$project" "$prefix/$project"
  echo "Patched dynamic library paths for $project" >> "$status"
done

hg_bin_dir="$prefix/eden_scm/bin"
edenfs_bin_dir="$prefix/eden/bin"
mononoke_bin_dir="$prefix/mononoke/bin"
edenfs="$edenfs_bin_dir/edenfs"
privhelper="$edenfs_bin_dir/edenfs_privhelper"

cat > "$prefix/fix_perms.sh" << EOF
#!/bin/bash

# Please run this script with sudo to set the required permissions for EdenFS.
#
# Both the EdenFS daemon and its associated helper binary need to be setuid
# root to work correctly. The daemon will drop its priviledges on startup, and
# will use the helper binary to perform subsequent operations that require
# elevated permissions.

for bin in "$edenfs" "$privhelper";
do
  chown root "\$bin"
  chmod u+s "\$bin"
done
EOF
chmod +x "$prefix/fix_perms.sh"

cat > "$prefix/env.rc" << EOF
export PATH="$hg_bin_dir:$edenfs_bin_dir:$mononoke_bin_dir:\$PATH"
alias eden="$edenfs_bin_dir/edenfsctl --config-dir=\$HOME/.eden"
alias getdeps="$getdeps"
EOF

rm "$status"
echo "EdenSCM installed successfully! Please run the following:"
echo
echo "sudo $prefix/fix_perms.sh"
echo "source $prefix/env.rc"
echo
