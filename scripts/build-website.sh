#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

rm -rf .build/website
mkdir -p .build/website/en .build/website/assets
cp website/index.html website/styles.css .build/website/
cp website/en/index.html .build/website/en/
cp docs/logo-web.png docs/website-cards-*.webp docs/website-list-*.webp \
    docs/paste-import-colors-light.webp docs/paste-import-colors-dark.webp \
    .build/website/assets/
touch .build/website/.nojekyll

printf 'Website built in .build/website/\n'
