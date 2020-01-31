#!/usr/local/bin/bash

set -euo pipefail

source .expeditor/scripts/release_habitat/shared.sh

# Get secrets! (our auth token and aws creds should be auto-injected but there's a bug:
# https://github.com/chef/ci-studio-common/issues/200)
eval "$(vault-util fetch-secret-env)"

export HAB_AUTH_TOKEN="${PIPELINE_HAB_AUTH_TOKEN}"
export HAB_BLDR_URL="${PIPELINE_HAB_BLDR_URL}"

channel=$(get_release_channel)

echo "--- Channel: $channel - bldr url: $HAB_BLDR_URL"

echo "--- Installing mac bootstrap package"
# subscribe to releases: https://github.com/habitat-sh/release-engineering/issues/84
bootstrap_package_version="$(cat MAC_BOOTSTRAPPER_VERSION)"
bootstrap_package_name="mac-bootstrapper-${bootstrap_package_version}-1"
curl "https://packages.chef.io/files/current/mac-bootstrapper/${bootstrap_package_version}/mac_os_x/10.12/${bootstrap_package_name}.dmg" -O
sudo hdiutil attach "${bootstrap_package_name}.dmg"
sudo installer -verbose -pkg "/Volumes/Habitat macOS Bootstrapper/${bootstrap_package_name}.pkg" -target /
sudo hdiutil detach "/Volumes/Habitat macOS Bootstrapper"
brew install wget
export PATH=/opt/mac-bootstrapper/embedded/bin:/usr/local/bin:$PATH

declare -g hab_binary
curlbash_hab "$BUILD_PKG_TARGET"
import_keys "${HAB_ORIGIN}"

########################################################################
# BEGIN CERTIFICATE SHENANIGANS

echo "--- Prepare cert file"
# So, originally, we got this cert file from Homebrew's openssl
# package. We currently need this because it gets baked into the
# binaries we ship as part of how our API client library works. We may
# be able to remove this in the near future, but for the time being,
# we can just grab a cert file from the Linux core/cacerts Habitat
# package.
cacerts_scratch_dir="cacerts_scratch"
mkdir "${cacerts_scratch_dir}"
${hab_binary} pkg download core/cacerts \
    --target=x86_64-linux \
    --download-directory="${cacerts_scratch_dir}"
cacerts_hart=$(find "${cacerts_scratch_dir}"/artifacts -type f -name 'core-cacerts-*-x86_64-linux.hart')

# GNU tail, tar, from the mac-bootstrapper
tail --lines=+6 "${cacerts_hart}" | \
    tar --extract \
        --verbose \
        --xz \
        --strip-components=8 \
        --wildcards "hab/pkgs/core/cacerts/*/*/ssl/certs"

cert_file="cacert.pem"
if [ ! -f "${cert_file}" ]; then
    echo "Couldn't extract ${cert_file} file from core/cacerts package!"
    exit 1
fi
export SSL_CERT_FILE
SSL_CERT_FILE="$(pwd)/${cert_file}"

# END CERTIFICATE SHENANIGANS
########################################################################

# We invoke hab-plan-build.sh directly via sudo, so we don't get the key management that studio provides.
# Copy keys from the user account Habitat cache to the system Habitat cache so that they are present for root.
sudo mkdir -p /hab/cache/keys
sudo cp -r ~/.hab/cache/keys/* /hab/cache/keys/

install_rustup

# set the rust toolchain
rust_toolchain="$(cat rust-toolchain)"
echo "--- :rust: Using Rust toolchain ${rust_toolchain}"
rustc --version # just 'cause I'm paranoid and I want to double check

echo "--- :habicat: Building components/hab"

HAB_BLDR_CHANNEL="${channel}" sudo -E bash \
        components/plan-build/bin/hab-plan-build.sh \
        components/hab
source results/last_build.env

echo "--- :habicat: Uploading ${pkg_ident:?} to ${HAB_BLDR_URL} in the '${channel}' channel"
${hab_binary} pkg upload \
              --channel="${channel}" \
              --auth="${HAB_AUTH_TOKEN}" \
              --no-build \
              "results/${pkg_artifact:?}"

echo "<br>* ${pkg_ident} (${BUILD_PKG_TARGET})" | buildkite-agent annotate --append --context "release-manifest"

set_target_metadata "${pkg_ident}" "${pkg_target}"
