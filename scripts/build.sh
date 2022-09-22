#!/bin/bash

# Set up working executables for Sapling (hg), EdenFS, and Mononoke.
#
# Building the various components of EdenSCM using getdeps.py can be fiddly,
# so this scripts helps automate the process. The basic steps for each project
# are:
#
# 1. Build the project with `getdeps.py build`. This will produce binaries that
#    are stored in a directory under /tmp. The intermediate build artifacts and
#    dependencies (such as 3rd party libraries that are downloaded and built
#    from source) are placed under a scratch directory, usually ~/.scratch.
#
# 2. Patch the binaries with `getdeps.py fixup-dyn-deps`. The built executables
#    will need to be patched to that their dynamic library paths point to the
#    ones built during step (1). On Linux systems, this is done via patchelf.
#    Note that this means that once copied to the destination directory, these
#    dynamic libraries CANNOT BE MOVED since that would break the executables.
#
# 3. Copy the built binaries to the destination directory. This is happens
#    automatically during step (2) for binaries that need to be patched (along
#    with the dynamic libraries they depend on). However, there may be other
#    build artifacts that weren't copied during the patching step (e.g. all of
#    hg's Python code). These need to be copied alongside the patched binaries.
#
# 4. Set up the environment so the executables can run. This includes setting
#    the required permissions on the binaries and setting up any required
#    environment variables. This script generates additional script files that
#    can be used to set up the environment.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Please specify an installation directory"
    exit 1
fi

projects=("eden_scm" "eden" "mononoke")

script_dir=$(dirname "$(realpath "$0")")
cd "$script_dir"
repo_path=$(git rev-parse --show-toplevel || true)

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
getdeps_py="build/fbcode_builder/getdeps.py"
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

for project in "${projects[@]}";
do
  tmp_install_dir="$($getdeps show-inst-dir "$project")"
  write_log "Temporary install directory for $project: $tmp_install_dir"

  # Avoid rebuilding the project if possible; the already-built files will
  # still be patched and copied to the specified destination directory. This
  # means that projects can be manually [re]built with getdeps.py, and those
  # artifacts with be patched and copied, allowing for faster iteration.
  if [ ! -d "$tmp_install_dir/bin" ]; then
    # getdeps.py will build each project and "install" the resulting build
    # artifacts into a temporary directory. Any binary artifacts likely won't
    # run at this point because they will be missing dynamic library paths to
    # any dependencies that were built from source by getdeps.
    write_log "Building project $project"
    $getdeps build "$project"
    write_log "Built project $project"
  else
    write_log "Skipping build for project $project"
  fi

  # Use patchelf to patch the executables with the correct paths to locally
  # built dynamic dependencies. The patched executables will be copied from
  # the temporary install directory to the actual desired install directory.
  write_log "Patching dynamic library paths for $project"
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
export EDENFS_SERVER_PATH="$edenfs_bin"
alias eden="$edenfs_bin_dir/edenfsctl --config-dir=\$HOME/.eden"
alias getdeps="$getdeps"
EOF

write_log "Done!"
echo "EdenSCM binaries have been installed in $prefix."
echo "Please run the following to setup the environment:"
echo
echo "  source $prefix/env.rc"
echo
echo "Attempting to set permissions for EdenFS binaries. If this fails (e.g.,"
echo "due to sudo prompting for a password), run the following:"
echo
echo "  sudo $prefix/fix_perms.sh"
echo

sudo --non-interactive "$prefix/fix_perms.sh"
