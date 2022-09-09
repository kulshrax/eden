#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Please specify an installation directory"
    exit 1
fi

repo_path=$(dirname "$(realpath "$0")")
getdeps_py="build/fbcode_builder/getdeps.py"

prefix=$(realpath "$1")
mkdir -p "$prefix"
cd "$prefix"

log_file="$prefix/build_status.log"

function write_log {
  echo "$(date '+%Y-%m-%d %H:%M:%S') " "$@" >> "$log_file"
}

write_log "Installing under: $prefix"

# If we're not running the script from within the eden repo itself, check if
# there's a copy of the repo in the installation directory, otherwise clone it.
if [ ! -f "$repo_path/$getdeps_py" ]; then
  repo="source"
  repo_url="https://github.com/kulshrax/eden.git"
  repo_path="$prefix/$repo"

  if [ ! -d "$repo_path" ]; then
    git clone "$repo_url" "$repo_path"
    write_log "Cloned repo to: $repo_path"
  fi
fi

write_log "Using repo at: $repo_path"

getdeps="python3 $repo_path/$getdeps_py"

for project in "eden_scm" "eden" "mononoke";
do
  if [ ! -d "$prefix/$project/bin" ]; then
    $getdeps build "$project" --install-dir="$prefix/$project"
    write_log "Built project $project"
  fi

  set -x
  $getdeps fixup-dyn-deps "$project" "$prefix/$project"
  set +x
  write_log "Patched dynamic library paths for $project"
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

write_log "Done!"
echo "EdenSCM installed successfully! Please run the following:"
echo
echo "sudo $prefix/fix_perms.sh"
echo "source $prefix/env.rc"
echo
