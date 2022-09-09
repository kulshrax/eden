#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Please specify an installation directory"
    exit 1
fi

prefix=$1
mkdir -p "$prefix"
cd "$prefix"

status="$prefix/status"
echo "Installing under: $prefix" > "$status"

repo="source"
repo_url="https://github.com/kulshrax/eden.git"
repo_path="$prefix/$repo"
getdeps="python3 $repo_path/build/fbcode_builder/getdeps.py"

if [ ! -d "$repo_path" ]; then
  git clone "$repo_url" "$repo_path"
  echo "Cloned repo to: $repo_path" >> "$status"
fi

for project in "eden_scm" "eden" "mononoke";
do
  $getdeps build "$project" --install-dir="$prefix/$project"
  echo "Built project $project" >> "$status"

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
  sudo chown root "\$bin"
  sudo chmod u+s "\$bin"
done
EOF
chmod +x "$prefix/fix_perms.sh"

cat > "$prefix/env.rc" << EOF
export PATH="$hg_bin_dir:$edenfs_bin_dir:$mononoke_bin_dir:\$PATH"
alias eden="$edenfs_bin_dir/edenfsctl --config-dir=\$HOME/.eden"
alias getdeps="$getdeps"
EOF

echo "Completed successfully" >> "$status"
