#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

rm -rf .build/website
mkdir -p .build/website/en .build/website/assets
cp website/index.html website/styles.css .build/website/
cp website/en/index.html .build/website/en/
cp docs/logo.png docs/website-cards-*.png docs/website-list-*.png \
    docs/paste-import-colors-light.png docs/paste-import-colors-dark.png \
    .build/website/assets/
touch .build/website/.nojekyll

printf 'Website built in .build/website/\n'
