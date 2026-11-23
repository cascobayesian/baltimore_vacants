#!/bin/sh
# Copy web/ into site_repo/ (GitHub Pages: cascobayesian/baltimore_vacants), wrapping index.html in a full HTML document.
# Then commit and push from site_repo/ (push in pieces if the connection times out).
set -e
cd "$(dirname "$0")/.."
rsync -a --exclude index.html --exclude .DS_Store web/ site_repo/
{ printf '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n<style>:root{color-scheme:light}body{margin:0;font:14px system-ui,sans-serif}img{max-width:100%%}[hidden]{display:none!important}</style>\n'
  awk '/^<\/style>$/ && !done {print; print "</head>\n<body>"; done=1; next} {print}' web/index.html; printf '</body>\n</html>\n'; } > site_repo/index.html
cp scripts/*.py scripts/*.R scripts/*.sh site_repo/pipeline/
echo "synced; now: cd site_repo && git add -A && git commit && git push"
