#!/usr/bin/env bash
set -euo pipefail

ndk_version="${1:-${ANDROID_NDK_VERSION:-}}"
if [[ -z "${ndk_version}" ]]; then
  echo "ANDROID_NDK_VERSION is not set."
  exit 1
fi

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/usr/local/lib/android/sdk}}"
if [[ ! -d "${sdk_root}" ]]; then
  echo "Android SDK root does not exist: ${sdk_root}"
  exit 1
fi

sdkmanager_bin=""
if command -v sdkmanager >/dev/null 2>&1; then
  sdkmanager_bin="$(command -v sdkmanager)"
elif [[ -x "${sdk_root}/cmdline-tools/latest/bin/sdkmanager" ]]; then
  sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
else
  for candidate in "${sdk_root}"/cmdline-tools/*/bin/sdkmanager; do
    if [[ -x "${candidate}" ]]; then
      sdkmanager_bin="${candidate}"
      break
    fi
  done
fi

if [[ -z "${sdkmanager_bin}" ]]; then
  echo "sdkmanager was not found under ${sdk_root}"
  exit 1
fi

ndk_dir="${sdk_root}/ndk/${ndk_version}"

delete_path() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    return 0
  fi

  rm -rf "${path}" 2>/dev/null || sudo rm -rf "${path}"
}

accept_licenses() {
  yes | "${sdkmanager_bin}" --sdk_root="${sdk_root}" --licenses >/dev/null || true
}

for attempt in 1 2 3; do
  echo "Installing Android NDK ${ndk_version} (attempt ${attempt}/3)"
  delete_path "${ndk_dir}"
  delete_path "${sdk_root}/.temp"
  delete_path "${HOME}/.android/cache"

  accept_licenses

  if "${sdkmanager_bin}" --sdk_root="${sdk_root}" --install "ndk;${ndk_version}"; then
    if [[ -f "${ndk_dir}/source.properties" ]]; then
      echo "Android NDK ${ndk_version} is ready at ${ndk_dir}"
      cat "${ndk_dir}/source.properties"
      exit 0
    fi

    echo "Android NDK ${ndk_version} is missing source.properties after install"
  fi

  sleep "$((attempt * 15))"
done

echo "Failed to install Android NDK ${ndk_version}"
exit 1
