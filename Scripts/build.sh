#!/bin/sh
# bl0cksh1t — canonical xcodebuild invocation.
#
# -skipPackagePluginValidation: SafariConverterLib's GenerateVersion build
# tool plugin is "unknown" to Xcode's plugin fingerprint store (no entry was
# ever written for it on this machine), so xcodebuild otherwise fails at
# "Validate plug-in" with "must be enabled before it can be used". Enabling
# it requires an interactive Xcode UI click; the flag is the documented
# non-interactive equivalent (Apple's own Xcode Cloud guidance).
set -eu
cd "$(dirname "$0")/.."

exec xcodebuild \
    -project bl0cksh1t.xcodeproj \
    -scheme bl0cksh1t \
    -skipPackagePluginValidation \
    "$@"
