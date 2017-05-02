/*
 *  Copyright (c) 2016-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */
#pragma once
#include <folly/Synchronized.h>
#include "eden/fs/inodes/DirstatePersistence.h"
#include "eden/fs/inodes/InodePtrFwd.h"
#include "eden/fs/inodes/gen-cpp2/overlay_types.h"
#include "eden/fs/model/Tree.h"
#include "eden/fs/service/gen-cpp2/EdenService.h"
#include "eden/fs/utils/PathFuncs.h"

namespace {
class DirectoryDelta;
}

namespace facebook {
namespace eden {

class ClientConfig;
class EdenMount;
class InodeBase;
class ObjectStore;
class Tree;
class TreeInode;

namespace fusell {
class InodeBase;
class MountPoint;
}

/**
 * Returns the single-char representation of the status used by `hg status`.
 * Note that this differs from the corresponding entry in the _VALUES_TO_NAMES
 * map for a Thrift enum.
 */
char hgStatusCodeChar(StatusCode code);

class HgStatus {
 public:
  explicit HgStatus(std::unordered_map<RelativePath, StatusCode>&& statuses)
      : statuses_(statuses) {}

  /**
   * What happens if `path` is not in the internal statuses_ map? Should it
   * return CLEAN or something else?
   */
  StatusCode statusForPath(RelativePathPiece path) const;

  size_t size() const {
    return statuses_.size();
  }

  bool operator==(const HgStatus& other) const {
    return statuses_ == other.statuses_;
  }

  /**
   * Returns something akin to what you would see when running `hg status`.
   * This is intended for debugging purposes: do not rely on the format of the
   * return value.
   */
  std::string toString() const;

  const std::unordered_map<RelativePath, StatusCode>* list() const {
    return &statuses_;
  }

 private:
  std::unordered_map<RelativePath, StatusCode> statuses_;
};

std::ostream& operator<<(std::ostream& os, const HgStatus& status);

struct DirstateAddRemoveError {
  DirstateAddRemoveError(RelativePathPiece p, folly::StringPiece s)
      : path{p}, errorMessage{s.str()} {}

  RelativePath path;
  std::string errorMessage;
};
inline bool operator==(
    const DirstateAddRemoveError& lhs,
    const DirstateAddRemoveError& rhs) {
  return lhs.path == rhs.path && lhs.errorMessage == rhs.errorMessage;
}
inline bool operator!=(
    const DirstateAddRemoveError& lhs,
    const DirstateAddRemoveError& rhs) {
  return !(lhs == rhs);
}
std::ostream& operator<<(
    std::ostream& os,
    const DirstateAddRemoveError& status);

/**
 * This is designed to be a simple implemenation of an Hg dirstate. It's
 * "simple" in that every call to `getStatus()` walks the entire overlay to
 * determine which files have been added/modified/removed, and then compares
 * those files with the base commit to determine the appropriate Hg status code.
 *
 * Ideally, we would cache information between calls to `getStatus()` to make
 * this more efficient, but this seems like an OK place to start. Once we have
 * a complete implementation built that is supported by a battery of tests, then
 * we can try to optimize things.
 *
 * For the moment, let's assume that we have the invariant that every file that
 * has been modified since the "base commit" exists in the overlay. This means
 * that we do not allow a non-commit snapshot to remove files from the overlay.
 * Rather, the only time the overlay gets "cleaned up" is in response to a
 * commit or an update.
 *
 * This may not be what we want in the long run, but we need to get basic
 * Mercurial stuff working first before we can worry about snapshots.
 */
class Dirstate {
 public:
  explicit Dirstate(EdenMount* mount);
  ~Dirstate();

  /**
   * Get the status information about files that are changed.
   *
   * This is used for implementing "hg status".  Returns the data as a thrift
   * structure that can be returned to the eden hg extension.
   *
   * @param listIgnored Whether or not to report information about ignored
   *     files.
   */
  ThriftHgStatus getStatus(bool listIgnored) const;

  /**
   * Analogous to `hg add <path1> <path2> ...` where each `<path>` identifies an
   * untracked file (or directory that contains untracked files) to be tracked.
   *
   * Note that if `paths` is empty, then nothing will be added. To do the
   * equivalent of `hg add .`, then `paths` should be a vector with one element
   * whose value is `RelativePathPiece("")`.
   */
  void addAll(
      const std::vector<RelativePathPiece>& paths,
      std::vector<DirstateAddRemoveError>* errorsToReport);

  /**
   * Analogous to `hg rm <path1> <path2> ...` where each `<path>` identifies a
   * file or directory in the manifest. (Note that the path may correspond to a
   * file that has already been removed from disk.)
   *
   * In Mercurial proper, `hg rm` can take multiple paths, some of which are
   * invalid arguments (they could be untracked files, for example). When this
   * happens:
   *
   * 1. `hg rm` is applied for the valid arguments.
   * 2. An error message is printed for each invalid argument.
   * 3. An exit code of 1 is returned.
   *
   * In order to support this behavior, this method can add entries to
   * errorsToReport, indicating error messages to present to the user. As such,
   * if this adds entries to errorsToReport, the corresponding exit code to
   * `hg rm` should be 1.
   */
  void removeAll(
      const std::vector<RelativePathPiece>& paths,
      bool force,
      std::vector<DirstateAddRemoveError>* errorsToReport);

  /**
   * Clean up the Dirstate after the current commit has changed.
   *
   * This removes Add and Remove directives if the corresponding files have
   * been added or removed in the new source control state.
   */
  folly::Future<folly::Unit> onSnapshotChanged(const Tree* rootTree);

 private:
  /**
   * Analogous to `hg rm <path>` where `<path>` is an ordinary file or symlink.
   */
  void remove(
      RelativePathPiece path,
      bool force,
      std::vector<DirstateAddRemoveError>* errorsToReport);

  /**
   * Note that EdenMount::getInodeBlocking() throws if path does not
   * correspond to an actual file. This helper function returns nullptr instead
   * in that case.
   */
  InodePtr getInodeBaseOrNull(RelativePathPiece path) const;

  /** The EdenMount object that owns this Dirstate */
  EdenMount* const mount_{nullptr};
  DirstatePersistence persistence_;
  /**
   * Manifest of files in the working copy whose status is not CLEAN. These are
   * also referred to as "nonnormal" files.
   * TODO(mbolin): Consider StringKeyedMap instead of unordered_map.
   */
  folly::Synchronized<
      std::unordered_map<RelativePath, overlay::UserStatusDirective>>
      userDirectives_;
};
}
}
