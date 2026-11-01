#!/bin/sh

set -eu

case "$#" in
  2)
    zarf_binary=$1
    zarf_subcommand=
    save_directory=$2
    ;;
  3)
    # Some launchers expose Zarf as a subcommand. Preserve both command words
    # when invoking embedded tools from this helper.
    zarf_binary=$1
    zarf_subcommand=$2
    save_directory=$3
    ;;
  *)
    echo "usage: build-save-oci.sh ZARF_BINARY [ZARF_SUBCOMMAND] SAVE_DIRECTORY" >&2
    exit 2
    ;;
esac

run_zarf() {
  if [ -n "$zarf_subcommand" ]; then
    "$zarf_binary" "$zarf_subcommand" "$@"
  else
    "$zarf_binary" "$@"
  fi
}

# An empty path deliberately disables the optional save import.
if [ -z "$save_directory" ]; then
  exit 0
fi

if [ "${save_directory#/}" = "$save_directory" ]; then
  echo "ERROR: SAVE_PATH must be an absolute path: $save_directory" >&2
  exit 1
fi

if [ ! -d "$save_directory" ]; then
  echo "ERROR: SAVE_PATH is not a directory: $save_directory" >&2
  exit 1
fi

if ! find "$save_directory" -maxdepth 1 -type f -name '*.zip' -print | grep -q .; then
  echo "ERROR: SAVE_PATH does not contain a .zip file: $save_directory" >&2
  exit 1
fi

if [ -z "${ZARF_REGISTRY:-}" ]; then
  echo "ERROR: the Zarf registry address is unavailable" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64|amd64)
    image_architecture=amd64
    ;;
  aarch64|arm64)
    image_architecture=arm64
    ;;
  *)
    echo "ERROR: unsupported image architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

work_directory=$(mktemp -d "${TMPDIR:-/tmp}/factorio-save-oci.XXXXXX")
layout_directory="$work_directory/layout"
blob_directory="$layout_directory/blobs/sha256"

cleanup() {
  rm -rf "$work_directory"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$blob_directory"

layer_file="$work_directory/layer.tar"
echo "Creating an OCI layer from $save_directory" >&2
(
  cd "$save_directory"
  run_zarf tools archiver compress . "$layer_file"
) >&2

layer_digest=$(run_zarf dev sha256sum "$layer_file")
layer_size=$(wc -c < "$layer_file" | tr -d '[:space:]')
save_tag="save-$(printf '%s' "$layer_digest" | cut -c1-16)"
mv "$layer_file" "$blob_directory/$layer_digest"

config_file="$work_directory/config.json"
printf '%s\n' \
  "{\"architecture\":\"$image_architecture\",\"config\":{},\"os\":\"linux\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:$layer_digest\"]}}" \
  > "$config_file"
config_digest=$(run_zarf dev sha256sum "$config_file")
config_size=$(wc -c < "$config_file" | tr -d '[:space:]')
mv "$config_file" "$blob_directory/$config_digest"

manifest_file="$work_directory/manifest.json"
printf '%s\n' \
  "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"sha256:$config_digest\",\"size\":$config_size},\"layers\":[{\"mediaType\":\"application/vnd.oci.image.layer.v1.tar\",\"digest\":\"sha256:$layer_digest\",\"size\":$layer_size}]}" \
  > "$manifest_file"
manifest_digest=$(run_zarf dev sha256sum "$manifest_file")
manifest_size=$(wc -c < "$manifest_file" | tr -d '[:space:]')
mv "$manifest_file" "$blob_directory/$manifest_digest"

printf '%s\n' '{"imageLayoutVersion":"1.0.0"}' > "$layout_directory/oci-layout"
printf '%s\n' \
  "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"sha256:$manifest_digest\",\"size\":$manifest_size,\"platform\":{\"architecture\":\"$image_architecture\",\"os\":\"linux\"},\"annotations\":{\"org.opencontainers.image.ref.name\":\"$save_tag\"}}]}" \
  > "$layout_directory/index.json"

# When given the cluster-facing Zarf registry reference, this embedded command
# automatically loads the Zarf state, opens a registry tunnel, supplies push
# credentials, and configures the Zarf-managed mTLS client certificate.
save_reference="$ZARF_REGISTRY/factorio-saves:$save_tag"
echo "Pushing $save_reference with the embedded Zarf registry client" >&2
run_zarf tools registry push "$layout_directory" "$save_reference" >&2

# Zarf's agent recognizes this as an already-rewritten internal reference and
# leaves it unchanged when the image volume is admitted.
printf '%s\n' "$save_reference"
