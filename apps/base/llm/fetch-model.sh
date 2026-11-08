#!/bin/sh
# Downloads the model once, and refuses to start the server if the file isn't the one pinned.
set -eu
dest="/models/${MODEL_FILE}"
if [ -f "$dest" ] && echo "${MODEL_SHA256}  $dest" | sha256sum -c -s; then
  echo "model already here and checksum matches"
  exit 0
fi
echo "downloading ${MODEL_FILE}"
curl -fsSL --retry 3 -o "$dest.part" "$MODEL_URL"
if ! echo "${MODEL_SHA256}  $dest.part" | sha256sum -c -s; then
  echo "checksum mismatch: refusing to use this file" >&2
  rm -f "$dest.part"
  exit 1
fi
mv "$dest.part" "$dest"
echo "model downloaded and checksum matches"
