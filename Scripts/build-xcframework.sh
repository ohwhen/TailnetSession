#!/usr/bin/env bash
# Builds a slim TailscaleKit.xcframework from the libtailscale commit in tailscale.ref.
#
#   Scripts/build-xcframework.sh            # writes build/TailscaleKit.xcframework(.zip)
#   MIN_IOS=18.0 Scripts/build-xcframework.sh
#
# Needs Xcode, Go (the version in libtailscale's go.mod) and git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$(tr -d '[:space:]' < "${ROOT}/tailscale.ref")"
MIN_IOS="${MIN_IOS:-17.0}"
SRC="${SRC:-${ROOT}/.build/libtailscale}"
OUT="${OUT:-${ROOT}/build}"
XCFRAMEWORK="${OUT}/TailscaleKit.xcframework"

OMIT_TAGS=(
	ts_omit_advertiseexitnode ts_omit_advertiseroutes ts_omit_appconnectors ts_omit_aws
	ts_omit_bird ts_omit_captiveportal ts_omit_capture ts_omit_clientupdate ts_omit_cloud
	ts_omit_completion ts_omit_dbus ts_omit_doctor ts_omit_drive ts_omit_iptables ts_omit_kube
	ts_omit_networkmanager ts_omit_osrouter ts_omit_portlist ts_omit_qrcodes ts_omit_relayserver
	ts_omit_resolved ts_omit_ssh ts_omit_synology ts_omit_systray ts_omit_taildrop
	ts_omit_tailnetlock ts_omit_wakeonlan
)

log() { printf '\033[1;34m[tailscalekit]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[tailscalekit]\033[0m %s\n' "$*" >&2; exit 1; }

for tool in git go xcodebuild xcrun perl strip ditto shasum; do
	command -v "${tool}" >/dev/null || fail "${tool} not found"
done
[[ "${REF}" =~ ^[0-9a-f]{40}$ ]] || fail "tailscale.ref must hold a full libtailscale commit sha, got '${REF}'"

if [[ ! -d "${SRC}/.git" ]]; then
	rm -rf "${SRC}"
	git clone --quiet https://github.com/tailscale/libtailscale.git "${SRC}"
fi
git -C "${SRC}" fetch --quiet origin +refs/heads/main:refs/remotes/origin/main
if [[ -f "$(git -C "${SRC}" rev-parse --absolute-git-dir)/shallow" ]]; then
	git -C "${SRC}" fetch --quiet --unshallow origin
fi
git -C "${SRC}" merge-base --is-ancestor "${REF}" refs/remotes/origin/main \
	|| fail "${REF} is not on tailscale/libtailscale main; a commit from a fork is reachable by sha but is not upstream code"
git -C "${SRC}" checkout --quiet --force --detach "${REF}"
git -C "${SRC}" clean --quiet -fdx
log "libtailscale ${REF}, iOS ${MIN_IOS}+"

tags="ios,$(IFS=,; echo "${OMIT_TAGS[*]}")"
patch() {
	local file="$1" expression="$2" expected="$3"
	perl -0pi -e "${expression}" "${file}"
	grep -qF -- "${expected}" "${file}" || fail "upstream $(basename "${file}") changed shape: '${expected}' missing after patching"
}
patch "${SRC}/Makefile" "s/go build -v -ldflags -w -tags ios /go build -v -ldflags '-w -s' -trimpath -tags '${tags}' /g" "-trimpath -tags '${tags}'"
patch "${SRC}/Makefile" 's/^c-archive-ios-sim: libtailscale_ios_sim_arm64\.a libtailscale_ios_sim_x86_64\.a/c-archive-ios-sim: libtailscale_ios_sim_arm64.a/m' "c-archive-ios-sim: libtailscale_ios_sim_arm64.a ##"
patch "${SRC}/Makefile" 's/^\tlipo -create -output libtailscale_ios_sim\.a libtailscale_ios_sim_x86_64\.a libtailscale_ios_sim_arm64\.a$/\tcp libtailscale_ios_sim_arm64.a libtailscale_ios_sim.a/m' "cp libtailscale_ios_sim_arm64.a libtailscale_ios_sim.a"
patch "${SRC}/swift/Makefile" "s{-destination 'generic/platform=iOS Simulator'}{-destination 'generic/platform=iOS Simulator' ARCHS=arm64 EXCLUDED_ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS}}g" "ARCHS=arm64 EXCLUDED_ARCHS=x86_64"
patch "${SRC}/swift/Makefile" "s{-destination 'generic/platform=iOS' }{-destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS} }g" "-destination 'generic/platform=iOS' IPHONEOS_DEPLOYMENT_TARGET=${MIN_IOS}"

log "building device + arm64 simulator slices"
make -C "${SRC}/swift" ios-fat

rm -rf "${XCFRAMEWORK}" "${XCFRAMEWORK}.zip" "${OUT}/LICENSES.txt"
mkdir -p "${OUT}"
cp -R "${SRC}/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework" "${XCFRAMEWORK}"

section() {
	printf '\n%s\n%s\n%s\n\n' "================================================================" "$1" "================================================================"
}

log "collecting licenses for everything linked into the binary"
device_binary="$(find "${XCFRAMEWORK}" -path '*ios-arm64/TailscaleKit.framework/TailscaleKit' -type f | head -n1)"
[[ -n "${device_binary}" ]] || fail "no device slice in ${XCFRAMEWORK}"
modules="$(go version -m "${device_binary}" | awk '
	$1 == "dep" { if (current != "") print current; current = ($3 ~ /^v/) ? $2 "@" $3 : ""; next }
	$1 == "=>" { current = ($3 ~ /^v/) ? $2 "@" $3 : ""; next }
	END { if (current != "") print current }
')"
[[ -n "${modules}" ]] || fail "could not read Go build info from ${device_binary}"
{
	echo "TailscaleKit.framework bundles the software below. Each section reproduces that project's license."
	section "github.com/tailscale/libtailscale @ ${REF}"
	cat "${SRC}/LICENSE"
	section "The Go standard library and runtime ($(go version -m "${device_binary}" | head -n1 | awk '{print $2}'))"
	cat "$(go env GOROOT)/LICENSE"
	scratch="$(mktemp -d)"
	while IFS= read -r module; do
		dir="$(cd "${scratch}" && GOFLAGS= go mod download -json "${module}" | sed -n 's/^[[:space:]]*"Dir": "\(.*\)",$/\1/p')"
		[[ -d "${dir}" ]] || fail "go mod download returned no directory for ${module}"
		found=0
		while IFS= read -r license; do
			section "${module} ($(basename "${license}"))"
			cat "${license}"
			found=1
		done < <(find "${dir}" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) | sort)
		[[ "${found}" == 1 ]] || fail "no license file found for ${module}"
	done <<< "${modules}"
	rm -rf "${scratch}"
} > "${OUT}/LICENSES.txt"
log "$(grep -c '^================================================================$' "${OUT}/LICENSES.txt" | awk '{print $1 / 2}') license sections"

log "stripping, trimming the module, adding the privacy manifest and licenses"
find "${XCFRAMEWORK}" -type d -name Project -path '*.swiftmodule/*' -prune -exec rm -rf {} +
find "${XCFRAMEWORK}" -type f \( -name '*.abi.json' -o -name '*.swiftsourceinfo' \) -delete
find "${XCFRAMEWORK}" -type f -name '*.swiftmodule' -path '*.swiftmodule/*' -delete
while IFS= read -r framework; do
	ls "${framework}"/Modules/TailscaleKit.swiftmodule/*.swiftinterface >/dev/null 2>&1 || fail "${framework} has no .swiftinterface"
	strip -x -S "${framework}/TailscaleKit"
	cp "${ROOT}/Resources/PrivacyInfo.xcprivacy" "${framework}/PrivacyInfo.xcprivacy"
	cp "${OUT}/LICENSES.txt" "${framework}/LICENSES.txt"
	minos="$(xcrun vtool -show-build "${framework}/TailscaleKit" | awk '$1 == "minos" {print $2; exit}')"
	[[ "${minos}" == "${MIN_IOS}" ]] || fail "${framework} has minos '${minos}', expected ${MIN_IOS}"
done < <(find "${XCFRAMEWORK}" -type d -name TailscaleKit.framework)

if grep -rqF -- "${HOME}" "${XCFRAMEWORK}"; then
	fail "the framework still contains the build machine's home path (${HOME})"
fi

(cd "${OUT}" && ditto -c -k --sequesterRsrc --keepParent TailscaleKit.xcframework TailscaleKit.xcframework.zip)
log "$(du -sh "${XCFRAMEWORK}" | cut -f1) unzipped, $(du -h "${XCFRAMEWORK}.zip" | cut -f1) zipped"
for binary in "${XCFRAMEWORK}"/*/TailscaleKit.framework/TailscaleKit; do
	slice="$(basename "$(dirname "$(dirname "${binary}")")")"
	log "${slice}: $(stat -f %z "${binary}") bytes, __TEXT $(size -m "${binary}" | awk '/^Segment __TEXT:/ {print $3; exit}') bytes"
done
checksum="$(shasum -a 256 "${XCFRAMEWORK}.zip" | cut -d' ' -f1)"
log "checksum ${checksum}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
	echo "checksum=${checksum}" >> "${GITHUB_OUTPUT}"
fi
