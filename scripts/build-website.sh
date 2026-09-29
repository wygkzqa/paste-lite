#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

mkdir -p .build/website/en .build/website/assets
cp website/index.html website/styles.css .build/website/
cp website/en/index.html .build/website/en/
cp docs/logo.png docs/group-tabs-light.png \
    docs/paste-import-colors-light.png docs/paste-import-colors-dark.png \
    .build/website/assets/
touch .build/website/.nojekyll

printf 'Website built in .build/website/\n'
