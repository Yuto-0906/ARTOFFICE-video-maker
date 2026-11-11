#!/bin/bash
set -euo pipefail

# This pinned FFmpeg build binds public C CoreMedia functions to the Swift
# overlay. That overlay does not re-export them on every supported iOS runtime.
# Correct only that dependency in build products; leave the package checkout intact.
overlay='/usr/lib/swift/libswiftCoreMedia.dylib'
framework='/System/Library/Frameworks/CoreMedia.framework/CoreMedia'
identity='-'
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == YES && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  identity="$EXPANDED_CODE_SIGN_IDENTITY"
fi
for directory in "$BUILT_PRODUCTS_DIR" "$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"; do
  for name in ffmpegkit libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale; do
    bundle="$directory/$name.framework"
    binary="$bundle/$name"
    if [[ -f "$binary" ]] && /usr/bin/otool -L "$binary" | /usr/bin/grep -F "$overlay" > /dev/null; then
      # Never edit a source/package-cache symlink through a build-product path.
      if [[ -L "$bundle" || -L "$binary" ]]; then
        echo "Refusing to patch a symlinked framework: $bundle" >&2
        exit 1
      fi
      /usr/bin/install_name_tool -change "$overlay" "$framework" "$binary"
      /usr/bin/codesign --force --sign "$identity" --timestamp=none "$bundle"
      echo "Corrected CoreMedia dependency: $name"
    fi
  done
done
