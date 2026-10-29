#!/usr/bin/env bash
# Build the exact OpenWrt packages revision and bake its NetBird APK into a guest.
set -euo pipefail
arch=${1:?usage: build-image.sh x86_64|arm64 OUTPUT_DIR}
output=${2:?output directory required}
release=25.12.1
packages_ref=${PACKAGES_REF:-8379ac12710eea0772da83066999ed44b82951b6}
[[ "$packages_ref" =~ ^[a-f0-9]{40}$ ]] || { echo 'PACKAGES_REF must be a full commit SHA' >&2; exit 2; }
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
git -C "$repo" checkout -q --detach "$packages_ref"
[[ $(git -C "$repo" rev-parse HEAD) == "$packages_ref" ]]
grep -Fx 'PKG_VERSION:=0.81.4' "$repo/net/netbird/Makefile"
base=https://downloads.openwrt.org/releases/$release/targets/$target
curl -fsSL "$base/sha256sums" -o "$work/sha256sums"
for kind in sdk imagebuilder; do
  prefix="openwrt-$kind-$release-$sdk_target"
  filename=$(curl -fsSL "$base/" | grep -oE "${prefix}"'[^"<>[:space:]]*Linux-x86_64[.]tar[.]zst' | sort -u | sed -n '1p')
  test -n "$filename"
  expected=$(awk -v n="*$filename" '$2==n {print $1}' "$work/sha256sums")
  test -n "$expected"
  curl -fsSL --retry 3 "$base/$filename" -o "$work/$filename"
  echo "$expected  $work/$filename" | sha256sum -c -
  tar --use-compress-program=unzstd -xf "$work/$filename" -C "$work"
  dir="$work/${filename%.tar.zst}"
  [[ -d "$dir" ]]
  if [[ "$kind" == sdk ]]; then sdk=$dir; else ib=$dir; fi
done
printf 'src-link packages %s\n' "$repo" > "$sdk/feeds.conf"
(
  cd "$sdk"
  ./scripts/feeds update packages
  ./scripts/feeds install netbird
  make defconfig
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
key="$ib/keys/sdk-public-key.pem"
test ! -e "$key"
cp "$sdk/public-key.pem" "$key"
restore() {
  if [[ -f "$ib/repositories.upstream" ]]; then mv -f "$ib/repositories.upstream" "$ib/repositories"; fi
  rm -f "$key"
}
trap restore EXIT
apk="$ib/staging_dir/host/bin/apk"
"$apk" adbsign --allow-untrusted --reset-signatures --sign-key "$sdk/private-key.pem" "$repo_dir"/netbird-*.apk
"$apk" --keys-dir "$ib/keys" mkndx --sign-key "$sdk/private-key.pem" --output "$repo_dir/packages.adb" "$repo_dir"/netbird-*.apk
cp "$ib/repositories" "$ib/repositories.upstream"
{ printf 'file://%s/packages.adb\n' "$repo_dir"; cat "$ib/repositories.upstream"; } > "$ib/repositories"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
make -C "$ib" image PACKAGES='netbird wget kmod-wireguard kmod-tun kmod-fs-9p kmod-9pnet kmod-9pvirtio' FILES="$root/image-overlay"
image=$(find "$ib/bin/targets" -type f -name "$pattern" -print -quit)
test -s "$image"
cp "$image" "$output/guest.img.gz"
sha256sum "$output/guest.img.gz" > "$output/guest.img.gz.sha256"
printf 'BUILT target=%s packages_ref=%s image=%s\n' "$target" "$packages_ref" "$output/guest.img.gz"
