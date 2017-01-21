/*
 *  Copyright (c) 2016-present, Facebook, Inc.
 *  All rights reserved.
 *
 *  This source code is licensed under the BSD-style license found in the
 *  LICENSE file in the root directory of this source tree. An additional grant
 *  of patent rights can be found in the PATENTS file in the same directory.
 *
 */
#include "PathFuncs.h"

#include <folly/Exception.h>
#include <folly/Optional.h>
#include <folly/portability/Stdlib.h>
#include <unistd.h>

using folly::StringPiece;

namespace facebook {
namespace eden {

StringPiece dirname(StringPiece path) {
  auto slash = path.rfind('/');
  if (slash != std::string::npos) {
    return path.subpiece(0, slash);
  }
  return "";
}

StringPiece basename(StringPiece path) {
  auto slash = path.rfind('/');
  if (slash != std::string::npos) {
    path.advance(slash + 1);
    return path;
  }
  return path;
}

AbsolutePath getcwd() {
  char cwd[PATH_MAX];
  if (!::getcwd(cwd, sizeof(cwd))) {
    folly::throwSystemError("getcwd() failed");
  }
  return AbsolutePath{cwd};
}

namespace {
struct CanonicalData {
  std::vector<StringPiece> components;
  bool isAbsolute{false};
};

CanonicalData canonicalPathData(StringPiece path) {
  CanonicalData data;
  const char* componentStart = path.begin();
  auto processSlash = [&](const char* end) {
    auto component = StringPiece{componentStart, end};
    componentStart = end + 1;
    if (component.empty()) {
      // Ignore empty components (doubled slash characters)
      // An empty component at the start of the string indicates an
      // absolute path.
      //
      // (POSIX specifies that "//" at the start of a path is special, and has
      // platform-specific behavior.  We intentionally ignore that, and treat a
      // leading "//" the same as a single leading "/".)
      if (component.begin() == path.begin()) {
        data.isAbsolute = true;
      }
    } else if (component == ".") {
      // ignore this component
    } else if (component == "..") {
      if (data.components.empty()) {
        if (!data.isAbsolute) {
          // We have no choice but to add ".." to the start
          data.components.push_back(component);
        }
      } else if (data.components.back() != "..") {
        data.components.pop_back();
      }
    } else {
      data.components.push_back(component);
    }
  };

  for (const char* p = path.begin(); p != path.end(); ++p) {
    if (*p == kDirSeparator) {
      processSlash(p);
    }
  }
  if (componentStart != path.end()) {
    processSlash(path.end());
  }

  return data;
}

AbsolutePath canonicalPathImpl(
    StringPiece path,
    folly::Optional<AbsolutePathPiece> base) {
  auto makeAbsolutePath = [](const std::vector<StringPiece>& parts) {
    if (parts.empty()) {
      return AbsolutePath{};
    }

    size_t length = 1;
    for (const auto& part : parts) {
      length += part.size();
    }

    folly::fbstring value;
    value.reserve(length);
    for (const auto& part : parts) {
      value.push_back('/');
      value.append(part.begin(), part.end());
    }

    return AbsolutePath{std::move(value)};
  };

  auto canon = canonicalPathData(path);
  if (canon.isAbsolute) {
    return makeAbsolutePath(canon.components);
  }

  // Get the components from the base path
  // For simplicity we are just re-using canonicalPathData() even though the
  // base path is guaranteed to already be in canonical form.
  CanonicalData baseCanon;
  AbsolutePath cwd;
  if (!base.hasValue()) {
    // canonicalPathData() returns StringPieces pointing to the input,
    // so we have to store the cwd in a variable that will persist until the
    // end of this function.
    cwd = getcwd();
    baseCanon = canonicalPathData(cwd.stringPiece());
  } else {
    baseCanon = canonicalPathData(base.value().stringPiece());
  }

  for (auto it = canon.components.begin(); it != canon.components.end(); ++it) {
    // There may be leading ".." parts, so we have to deal with them here
    if (*it == "..") {
      if (!baseCanon.components.empty()) {
        baseCanon.components.pop_back();
      }
    } else {
      // Once we found a non-".." component, none of the rest can be "..",
      // so add everything else and break out of the loop
      baseCanon.components.insert(
          baseCanon.components.end(), it, canon.components.end());
      break;
    }
  }

  return makeAbsolutePath(baseCanon.components);
}
}

AbsolutePath canonicalPath(folly::StringPiece path) {
  // Pass in folly::none.
  // canonicalPathImpl() will only call getcwd() if it is actually necessary.
  return canonicalPathImpl(path, folly::none);
}

AbsolutePath canonicalPath(folly::StringPiece path, AbsolutePathPiece base) {
  return canonicalPathImpl(path, folly::Optional<AbsolutePathPiece>{base});
}

AbsolutePath realpath(const char* path) {
  auto pathBuffer = ::realpath(path, nullptr);
  if (!pathBuffer) {
    folly::throwSystemError("realpath(", path, ") failed");
  }
  SCOPE_EXIT {
    free(pathBuffer);
  };

  return AbsolutePath(pathBuffer);
}

AbsolutePath realpath(StringPiece path) {
  // The input may not be nul-terminated, so we have to construct a std::string
  return realpath(path.str().c_str());
}
}
}
