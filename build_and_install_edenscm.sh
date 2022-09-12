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

# Since the build process spews a lot of output to both stdout and stderr,
# write this script's progress to a log file the user can follow with tail -f.
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
  tmp_install_dir="$($getdeps show-inst-dir $project)"
  write_log "Temporary install directory for $project: $tmp_install_dir"

  # Avoid rebuilding the project if possible; the already-built files will
  # still be patched and copied to the specified destination directory.
  if [ ! -d "$tmp_install_dir/bin" ]; then
    # getdeps.py will build each project and "install" the resulting build
    # artifacts into a temporary directory. Any binary artifacts likely won't
    # run at this point because they will be missing dynamic library paths to
    # any dependencies that were built from source by getdeps.
    $getdeps build "$project"
    write_log "Built project $project"
  else
    write_log "Skipping build for project $project"
  fi

  # Use patchelf to patch the executables with the correct paths to locally
  # built dynamic dependencies. The patched executables will be copied from
  # the temporary install directory to the actual desired install directory.
  $getdeps fixup-dyn-deps "$project" "$prefix/$project"
  write_log "Patched dynamic library paths for $project"

  # Copy any files that weren't copied in the above patching step. These would
  # be any non-binary files, such as scripts and other non-executable build
  # artifacts. Notably, this includes all of Mercurial's Python code.
  cp -nr "$tmp_install_dir" "$prefix"
  write_log "Copied non-binary files to $prefix/$project"
done

hg_bin_dir="$prefix/eden_scm/bin"
edenfs_bin_dir="$prefix/eden/bin"
mononoke_bin_dir="$prefix/mononoke/bin"

edenfs_bin="$edenfs_bin_dir/edenfs"
privhelper_bin="$edenfs_bin_dir/edenfs_privhelper"

# The generated EdenFS binaries need to be owned by root and have the setuid
# bit set. Since that requires `sudo` (and we don't want this script to wait
# for the user to type their password), write a script that the user can run
# under sudo to fix the permissions.
cat > "$prefix/fix_perms.sh" << EOF
#!/bin/bash

# Please run this script with sudo to set the required permissions for EdenFS.
#
# Both the EdenFS daemon and its associated helper binary need to be setuid
# root to work correctly. The daemon will drop its privileges on startup, and
# will use the helper binary to perform subsequent operations that require
# elevated permissions.

for bin in "$edenfs_bin" "$privhelper_bin";
do
  chown root "\$bin"
  chmod u+s "\$bin"
done
EOF
chmod +x "$prefix/fix_perms.sh"

# Write out an RC file that the user can source to update their environment to
# use the newly-built binaries.
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
