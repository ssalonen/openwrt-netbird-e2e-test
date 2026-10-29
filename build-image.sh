#!/usr/bin/env bash
# Build the exact OpenWrt packages revision and bake its NetBird APK into a guest.
set -euo pipefail
arch=${1:?usage: build-image.sh x86_64|arm64 OUTPUT_DIR}
output=${2:?output directory required}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
release=${OPENWRT_RELEASE:?set OPENWRT_RELEASE to snapshot or 25.12.1}
pr_number=${PR_NUMBER:?set PR_NUMBER to the resolved PR number}
packages_ref=${PACKAGES_REF:?set PACKAGES_REF to the resolved PR head SHA}
[[ "$pr_number" =~ ^[1-9][0-9]{0,7}$ ]] || { echo 'invalid PR number' >&2; exit 2; }
[[ "$packages_ref" =~ ^[a-f0-9]{40}$ ]] || { echo 'PACKAGES_REF must be a full commit SHA' >&2; exit 2; }
[[ "$release" == snapshot || "$release" == 25.12.1 ]] || { echo 'unsupported OpenWrt release' >&2; exit 2; }
case "$arch" in
  x86_64) target=x86/64; sdk_target=x86-64; pattern='*ext4-combined.img.gz' ;;
  arm64) target=armsr/armv8; sdk_target=armsr-armv8; pattern='*ext4-combined-efi.img.gz' ;;
  *) echo "unsupported architecture: $arch" >&2; exit 2 ;;
esac
[[ $(uname -m) == x86_64 ]] || { echo 'SDK and ImageBuilder require an x86_64 build host' >&2; exit 1; }
for bin in curl git tar zstd make sha256sum; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done
mkdir -p "$output"; output=$(realpath "$output")
work=${RUNNER_TEMP:-"$output"}/openwrt-build-$arch
mkdir -p "$work"
repo="$work/packages"
if [[ -e "$repo" ]]; then echo "refusing existing checkout: $repo" >&2; exit 1; fi
git clone -q --filter=blob:none https://github.com/openwrt/packages.git "$repo"
git -C "$repo" fetch -q --no-tags origin "refs/pull/$pr_number/head"
[[ $(git -C "$repo" rev-parse FETCH_HEAD) == "$packages_ref" ]] || { echo 'PR head changed since resolution' >&2; exit 1; }
git -C "$repo" checkout -q --detach FETCH_HEAD
[[ $(git -C "$repo" rev-parse HEAD) == "$packages_ref" ]]
grep -Fx 'PKG_VERSION:=0.81.4' "$repo/net/netbird/Makefile"
if [[ "$release" == snapshot ]]; then
  base="https://downloads.openwrt.org/snapshots/targets/$target"
  prefix_release=''
else
  base="https://downloads.openwrt.org/releases/$release/targets/$target"
  prefix_release="$release-"
fi
curl -fsSL "$base/version.buildinfo" -o "$work/version.buildinfo"
curl -fsSL "$base/sha256sums" -o "$work/sha256sums"
for kind in sdk imagebuilder; do
  prefix="openwrt-$kind-$prefix_release$sdk_target"
  filename=$(curl -fsSL "$base/" | grep -oE "${prefix}"'[^"<>[:space:]]*Linux-x86_64[.]tar[.]zst' | sort -u | sed -n '1p')
  test -n "$filename"
  expected=$(awk -v n="*$filename" '$2==n {print $1}' "$work/sha256sums")
  test -n "$expected"
  printf '%s %s\n' "$filename" "$expected" > "$work/$kind.metadata"
  curl -fsSL --retry 3 "$base/$filename" -o "$work/$filename"
  echo "$expected  $work/$filename" | sha256sum -c -
  tar --use-compress-program=unzstd -xf "$work/$filename" -C "$work"
  dir="$work/${filename%.tar.zst}"
  [[ -d "$dir" ]]
  if [[ "$kind" == sdk ]]; then sdk=$dir; else ib=$dir; fi
done
printf 'src-link packages %s\n' "$repo" > "$sdk/feeds.conf"
if [[ "$release" == snapshot ]]; then
  firmware_commit=$(PYTHONPATH="$root" python3 -c 'from provenance import resolve_commit; import pathlib,sys; print(resolve_commit(pathlib.Path(sys.argv[1]).read_text().strip().rsplit("-",1)[-1]))' "$work/version.buildinfo")
  [[ "$firmware_commit" =~ ^[a-f0-9]{40}$ ]]
  mkdir -p "$sdk/package/system/ubus" "$sdk/package/libs/libubox"
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/openwrt/openwrt/$firmware_commit/package/system/ubus/Makefile" \
    -o "$sdk/package/system/ubus/Makefile"
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/openwrt/openwrt/$firmware_commit/package/libs/libubox/Makefile" \
    -o "$sdk/package/libs/libubox/Makefile"
fi
(
  cd "$sdk"
  ./scripts/feeds update packages
  ./scripts/feeds install netbird
  make defconfig
  if [[ "$release" == snapshot ]]; then
    make -j2 package/libs/libubox/compile V=sc
    make -j2 package/system/ubus/compile V=sc
  fi
  make -j2 package/feeds/packages/netbird/compile V=sc
)
package=$(find "$sdk/bin/packages" -type f -name 'netbird-0.81.4-r1.apk' -print -quit)
test -s "$package"
sha256sum "$package" > "$output/netbird.apk.sha256"
# ImageBuilder has its own APK v3 signer and cannot consume the SDK signature
# blindly. Copy only the verified package; the original remains untouched.
repo_dir="$ib/local-repository"
mkdir "$repo_dir"
cp "$package" "$repo_dir/"
if [[ "$release" == snapshot ]]; then
  libubus=$(find "$sdk/bin/packages" -type f -name 'libubus*.apk' ! -name 'libubus-lua*' -print -quit)
  test -s "$libubus"
  cp "$libubus" "$repo_dir/"
  sha256sum "$libubus" > "$output/libubus.apk.sha256"
fi
key="$ib/keys/sdk-public-key.pem"
test ! -e "$key"
cp "$sdk/public-key.pem" "$key"
restore() {
  if [[ -f "$ib/repositories.upstream" ]]; then mv -f "$ib/repositories.upstream" "$ib/repositories"; fi
  rm -f "$key"
}
trap restore EXIT
apk="$ib/staging_dir/host/bin/apk"
local_apks=("$repo_dir"/netbird-*.apk)
if [[ "$release" == snapshot ]]; then local_apks+=("$repo_dir"/libubus*.apk); fi
for local_apk in "${local_apks[@]}"; do
  "$apk" adbsign --allow-untrusted --reset-signatures --sign-key "$sdk/private-key.pem" "$local_apk"
done
"$apk" --keys-dir "$ib/keys" mkndx --sign-key "$sdk/private-key.pem" --output "$repo_dir/packages.adb" "${local_apks[@]}"
cp "$ib/repositories" "$ib/repositories.upstream"
{ printf 'file://%s/packages.adb\n' "$repo_dir"; cat "$ib/repositories.upstream"; } > "$ib/repositories"
make -C "$ib" image PACKAGES='netbird wget coreutils-timeout kmod-wireguard kmod-tun kmod-fs-9p kmod-9pnet kmod-9pvirtio' FILES="$root/image-overlay"
image=$(find "$ib/bin/targets" -type f -name "$pattern" -print -quit)
test -s "$image"
cp "$image" "$output/guest.img.gz"
sha256sum "$output/guest.img.gz" > "$output/guest.img.gz.sha256"
BUILD_WORK="$work" BUILD_OUTPUT="$output" TARGET_URL="$base" GUEST_ARCH="$arch" \
  python3 "$root/provenance.py"
printf 'BUILT target=%s packages_ref=%s image=%s\n' "$target" "$packages_ref" "$output/guest.img.gz"
