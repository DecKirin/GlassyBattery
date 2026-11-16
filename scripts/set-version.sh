#!/usr/bin/env bash
#
# The app's version, in one place: MARKETING_VERSION (CFBundleShortVersionString, a semantic
# version "MAJOR.MINOR.PATCH") on every target, and CURRENT_PROJECT_VERSION (CFBundleVersion)
# derived from it as MAJOR*10000 + MINOR*100 + PATCH, so 1.14.0 is build 11400.
#
# The build number is what Sparkle compares to decide whether a release is newer, so it must
# grow with every release. Deriving it from the version keeps that true without a counter to
# remember, and keeps local builds and CI builds of one version identical. MINOR and PATCH stay
# below 100 for it to work.
#
#   scripts/set-version.sh 1.14.0    # set every target to 1.14.0 (build 11400)
#   scripts/set-version.sh --print   # print "<version> <build>"
#   scripts/set-version.sh --check   # exit 1 unless every target agrees and the build matches

set -euo pipefail

PBXPROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/GlassyBattery.xcodeproj/project.pbxproj"

die() { echo "error: $*" >&2; exit 1; }

build_number() {
    local major minor patch
    IFS=. read -r major minor patch <<<"$1"
    echo $((10#$major * 10000 + 10#$minor * 100 + 10#$patch))
}

valid() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]]
}

versions() { sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' "$PBXPROJ" | sort -u; }
builds() { sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);$/\1/p' "$PBXPROJ" | sort -u; }

check() {
    local v b
    [[ $(versions | wc -l) -eq 1 ]] || die "targets disagree on MARKETING_VERSION: $(versions | tr '\n' ' ')— run scripts/set-version.sh <version>"
    [[ $(builds | wc -l) -eq 1 ]] || die "targets disagree on CURRENT_PROJECT_VERSION: $(builds | tr '\n' ' ')— run scripts/set-version.sh <version>"
    v=$(versions)
    b=$(builds)
    valid "$v" || die "MARKETING_VERSION $v isn't MAJOR.MINOR.PATCH (MINOR and PATCH below 100)"
    [[ "$b" == "$(build_number "$v")" ]] || die "build $b doesn't match version $v (expected $(build_number "$v")) — run scripts/set-version.sh $v"
}

case "${1:-}" in
    --print)
        check
        echo "$(versions) $(builds)"
        ;;
    --check)
        check
        echo "version $(versions), build $(builds)"
        ;;
    ""|-h|--help)
        sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        ;;
    *)
        valid "$1" || die "$1 isn't MAJOR.MINOR.PATCH (MINOR and PATCH below 100)"
        build=$(build_number "$1")
        sed -i '' -E \
            -e "s/^([[:space:]]*MARKETING_VERSION = ).*;$/\1$1;/" \
            -e "s/^([[:space:]]*CURRENT_PROJECT_VERSION = ).*;$/\1$build;/" \
            "$PBXPROJ"
        check
        echo "version $1, build $build"
        ;;
esac
