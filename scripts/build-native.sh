#!/usr/bin/env bash
set -euo pipefail

# Builds the native Barometer library with barometer-go's own build script and
# places it where the plugin expects it. The commit comes from
# scripts/barometer-go.revision unless BAROMETER_GO_DIR names a checkout to build.

target=${1:-}
case "$target" in
  android) artifact=Barometer.aar; dest=android/libs ;;
  apple) artifact=Barometer.xcframework; dest=ios/Frameworks ;;
  *) echo 'Usage: bash scripts/build-native.sh android|apple' >&2; exit 2 ;;
esac

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/barometer-flutter-native.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ -n "${BAROMETER_GO_DIR:-}" ]; then
  source=$(cd "$BAROMETER_GO_DIR" && pwd)
  echo "Building from local checkout at $(git -C "$source" rev-parse HEAD)"
else
  revision=$(tr -d '[:space:]' < "$root/scripts/barometer-go.revision")
  case "$revision" in
    *[!0-9a-f]* | '') echo 'scripts/barometer-go.revision must hold a full commit hash' >&2; exit 1 ;;
  esac
  [ "${#revision}" -eq 40 ] || { echo 'scripts/barometer-go.revision must hold a full commit hash' >&2; exit 1; }
  source="$work/barometer-go"
  git init -q "$source"
  git -C "$source" fetch -q --depth 1 https://github.com/tv-rain/barometer-go.git "$revision"
  git -C "$source" checkout -q --detach FETCH_HEAD
  echo "Building barometer-go $revision"
fi

make -C "$source" "mobile-$target" MOBILE_OUT="$work/out"

rm -rf "${root:?}/$dest"
mkdir -p "$root/$dest"
cp "$work/out/$artifact.build-info.txt" "$root/$dest/"
if [ "$target" = android ]; then
  # AGP rejects a direct .aar file dependency in a library, so the AAR is
  # served from a plugin-local Maven repository that android/build.gradle.kts
  # registers.
  module="$root/$dest/maven/com/tvrain/barometer/barometer/local"
  mkdir -p "$module"
  cp "$work/out/$artifact" "$module/barometer-local.aar"
  cat > "$module/barometer-local.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.tvrain.barometer</groupId>
  <artifactId>barometer</artifactId>
  <version>local</version>
  <packaging>aar</packaging>
</project>
POM
else
  cp -R "$work/out/$artifact" "$root/$dest/"
fi
echo "Wrote $dest"
