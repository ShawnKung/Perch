#!/bin/bash
set -euo pipefail

tag="${1:?missing release tag}"
run_number="${2:?missing CI run number}"
plist="${3:?missing Info.plist}"

# Apple bundle versions are numeric; reject prereleases and ambiguous leading zeroes.
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo 'Release tag must have the form vMAJOR.MINOR.PATCH, without leading zeroes.' >&2
  exit 1
fi
if [[ ! "$run_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'CI run number must be a positive integer.' >&2
  exit 1
fi
base_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
if [[ ! "$base_build" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo 'The source CFBundleVersion must be a non-negative integer.' >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${tag#v}" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((base_build + run_number))" "$plist"
