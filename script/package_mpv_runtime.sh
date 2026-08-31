#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 --libmpv PATH --version VERSION --output DIR [--base-url URL] [--sign IDENTITY]"
}

libmpv_path=""
runtime_version=""
output_dir=""
base_url=""
signing_identity="-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --libmpv) libmpv_path="$2"; shift 2 ;;
    --version) runtime_version="$2"; shift 2 ;;
    --output) output_dir="$2"; shift 2 ;;
    --base-url) base_url="${2%/}"; shift 2 ;;
    --sign) signing_identity="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$libmpv_path" || -z "$runtime_version" || -z "$output_dir" ]]; then
  usage
  exit 2
fi
if [[ ! "$runtime_version" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Version may contain only letters, numbers, dots, underscores, and hyphens." >&2
  exit 2
fi
base_url_pattern='^https://[A-Za-z0-9._~:/?%+=,&-]+$'
if [[ -n "$base_url" && ! "$base_url" =~ $base_url_pattern ]]; then
  echo "Base URL must be an HTTPS URL without spaces, quotes, or backslashes." >&2
  exit 2
fi

libmpv_path=$(realpath "$libmpv_path")
if [[ ! -f "$libmpv_path" ]]; then
  echo "libmpv does not exist: $libmpv_path" >&2
  exit 1
fi

if otool -L "$libmpv_path" | tail -n +2 | awk '{print $1}' | grep -Eq '(^|/)libavdevice([.][0-9]+)*[.]dylib$'; then
  echo "Refusing to package libmpv with libavdevice: it conflicts with FlowVision's embedded FFmpegKit runtime." >&2
  echo "Build libmpv with -Dlibavdevice=disabled, then package that library instead." >&2
  exit 1
fi

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)

architectures=$(lipo -archs "$libmpv_path")
if [[ "$architectures" == *" "* ]]; then
  echo "Package one architecture at a time; found: $architectures" >&2
  exit 1
fi
architecture="$architectures"
if [[ "$architecture" != "arm64" ]]; then
  echo "FlowVision runtime packages are arm64-only; found: $architecture" >&2
  exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flowvision-mpv-runtime.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
package_dir="$work_dir/package"
frameworks_dir="$package_dir/Frameworks"
licenses_dir="$package_dir/LICENSES"
mkdir -p "$frameworks_dir" "$licenses_dir"

queue_file="$work_dir/queue"
seen_file="$work_dir/seen"
map_file="$work_dir/map"
printf '%s\n' "$libmpv_path" > "$queue_file"
: > "$seen_file"
: > "$map_file"

while [[ -s "$queue_file" ]]; do
  current=$(sed -n '1p' "$queue_file")
  sed '1d' "$queue_file" > "$queue_file.next"
  mv "$queue_file.next" "$queue_file"
  resolved=$(realpath "$current" 2>/dev/null || true)
  [[ -n "$resolved" && -f "$resolved" ]] || continue
  grep -Fqx "$resolved" "$seen_file" && continue
  printf '%s\n' "$resolved" >> "$seen_file"

  if [[ "$resolved" == "$libmpv_path" ]]; then
    # MPVRuntimeManager and the loader use this stable ABI-level filename even
    # when the input was a more deeply versioned Homebrew Cellar file.
    basename_value="libmpv.2.dylib"
  else
    basename_value=$(basename "$current")
  fi
  if grep -Fq "|$basename_value" "$map_file"; then
    echo "Dependency basename collision: $basename_value" >&2
    exit 1
  fi
  printf '%s|%s\n' "$resolved" "$basename_value" >> "$map_file"
  dependency_architectures=$(lipo -archs "$resolved")
  if ! tr ' ' '\n' <<< "$dependency_architectures" | grep -Fqx "$architecture"; then
    echo "Dependency does not contain $architecture: $resolved ($dependency_architectures)" >&2
    exit 1
  fi
  if [[ "$dependency_architectures" == *" "* ]]; then
    lipo "$resolved" -thin "$architecture" -output "$frameworks_dir/$basename_value"
  else
    cp -p "$resolved" "$frameworks_dir/$basename_value"
  fi

  otool -L "$resolved" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/usr/local/*)
        dependency_resolved=$(realpath "$dependency" 2>/dev/null || true)
        [[ -n "$dependency_resolved" && -f "$dependency_resolved" ]] && printf '%s\n' "$dependency_resolved" >> "$queue_file"
        ;;
    esac
  done
done

if awk -F'|' 'tolower($2) ~ /^libavdevice([.][0-9]+)*[.]dylib$/ { found = 1 } END { exit !found }' "$map_file"; then
  echo "Refusing to package a transitive libavdevice dependency; rebuild libmpv without libavdevice." >&2
  exit 1
fi

while IFS='|' read -r source_path basename_value; do
  destination="$frameworks_dir/$basename_value"
  install_name_tool -id "@rpath/$basename_value" "$destination"
  otool -L "$destination" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/usr/local/*)
        dependency_resolved=$(realpath "$dependency" 2>/dev/null || true)
        replacement=$(awk -F'|' -v path="$dependency_resolved" '$1 == path { print $2; exit }' "$map_file")
        if [[ -z "$replacement" ]]; then
          echo "Unpackaged dependency: $dependency" >&2
          exit 1
        fi
        install_name_tool -change "$dependency" "@loader_path/$replacement" "$destination"
        ;;
    esac
  done

  while IFS= read -r dependency; do
    case "$dependency" in
      "@rpath/$basename_value"|/usr/lib/*|/System/Library/*) ;;
      @loader_path/*)
        loader_relative=${dependency#@loader_path/}
        if [[ "$loader_relative" == */* || ! -f "$frameworks_dir/$loader_relative" ]]; then
          echo "Missing packaged dependency: $basename_value -> $dependency" >&2
          exit 1
        fi
        ;;
      *)
        echo "Runtime dependency was not made self-contained: $basename_value -> $dependency" >&2
        exit 1
        ;;
    esac
  done < <(otool -L "$destination" | tail -n +2 | awk '{print $1}')

  case "$source_path" in
    /opt/homebrew/Cellar/*) cellar_prefix="/opt/homebrew/Cellar" ;;
    /usr/local/Cellar/*) cellar_prefix="/usr/local/Cellar" ;;
    *) cellar_prefix="" ;;
  esac
  if [[ -n "$cellar_prefix" ]]; then
    cellar_relative=${source_path#"$cellar_prefix"/}
    formula_name=${cellar_relative%%/*}
    formula_root="$cellar_prefix/$formula_name"
    if [[ "$formula_root" != "$source_path" && -d "$formula_root" && ! -d "$licenses_dir/$formula_name" ]]; then
      mkdir -p "$licenses_dir/$formula_name"
      find "$formula_root" -maxdepth 3 -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'copyright*' \) -print0 2>/dev/null |
        while IFS= read -r -d '' license_file; do
          license_relative=${license_file#"$formula_root"/}
          license_destination="$licenses_dir/$formula_name/$license_relative"
          mkdir -p "$(dirname "$license_destination")"
          cp "$license_file" "$license_destination"
        done
    fi
  fi

  if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - "$destination"
  else
    codesign --force --options runtime --timestamp --sign "$signing_identity" "$destination"
  fi
  codesign --verify --strict "$destination"
done < "$map_file"

cat > "$package_dir/README.txt" <<EOF
FlowVision optional video playback runtime
Version: $runtime_version
Architecture: $architecture

This component is loaded only by FlowVision and may be removed from:
~/Library/Application Support/FlowVision/Runtime/mpv
EOF

archive_name="FlowVision-mpv-runtime-$runtime_version-$architecture.zip"
archive_path="$output_dir/$archive_name"
rm -f "$archive_path"
(cd "$package_dir" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$archive_path" Frameworks LICENSES README.txt)

archive_sha=$(shasum -a 256 "$archive_path" | awk '{print $1}')
archive_size=$(stat -f %z "$archive_path")
if [[ -n "$base_url" ]]; then
  asset_url="$base_url/$archive_name"
else
  asset_url="$archive_name"
fi

manifest_path="$output_dir/mpv-runtime-manifest.json"
manifest_work="$work_dir/mpv-runtime-manifest.plist"
if [[ ! -f "$manifest_path" ]]; then
  plutil -create xml1 "$manifest_work"
  plutil -insert schemaVersion -integer 1 "$manifest_work"
  plutil -insert assets -array "$manifest_work"
else
  plutil -convert xml1 -o "$manifest_work" "$manifest_path"
  manifest_schema=$(plutil -extract schemaVersion raw -o - "$manifest_work" 2>/dev/null || true)
  manifest_assets_type=$(plutil -type assets "$manifest_work" 2>/dev/null || true)
  if [[ "$manifest_schema" != "1" || "$manifest_assets_type" != "array" ]]; then
    echo "Existing manifest is not a schemaVersion 1 runtime manifest: $manifest_path" >&2
    exit 1
  fi
fi

asset_plist="$work_dir/asset.plist"
plutil -create xml1 "$asset_plist"
plutil -insert version -string "$runtime_version" "$asset_plist"
plutil -insert architecture -string "$architecture" "$asset_plist"
plutil -insert url -string "$asset_url" "$asset_plist"
plutil -insert sha256 -string "$archive_sha" "$asset_plist"
plutil -insert downloadSize -integer "$archive_size" "$asset_plist"
asset_json=$(plutil -convert json -o - "$asset_plist")

asset_count=$(plutil -extract assets raw -o - "$manifest_work")
for ((index = asset_count - 1; index >= 0; index--)); do
  existing_architecture=$(plutil -extract "assets.$index.architecture" raw -o - "$manifest_work" 2>/dev/null || true)
  if [[ "$existing_architecture" == "$architecture" ]]; then
    plutil -remove "assets.$index" "$manifest_work"
  fi
done
asset_count=$(plutil -extract assets raw -o - "$manifest_work")
plutil -insert "assets.$asset_count" -json "$asset_json" "$manifest_work"
plutil -convert json -r -o "$manifest_path" "$manifest_work"

echo "Created $archive_path"
echo "Updated $manifest_path"
echo "Libraries: $(wc -l < "$map_file" | tr -d ' ')"
echo "Compressed bytes: $archive_size"
