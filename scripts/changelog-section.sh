#!/bin/sh
# Prints one version's section of CHANGELOG.md (without its heading), for
# release notes: scripts/changelog-section.sh 0.1.7
set -e
v="$1"
awk -v v="$v" '
  $0 ~ "^## \\[" v "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found && /^\[[^]]+\]: / { exit }
  found { print }
' "$(dirname "$0")/../CHANGELOG.md" | sed -e '/./,$!d'
