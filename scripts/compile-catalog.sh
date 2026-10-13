#!/bin/bash
# Compile the String Catalog inside a SwiftPM resource bundle into per-language
# tables, where the build system left it verbatim.
#
# Xcode's build system compiles `Localizable.xcstrings` into `<lang>.lproj`
# tables; SwiftPM's native build system copies the catalog as it is, and no
# macOS reads a catalog at run time (verified against macOS 27: the lookup
# falls back to the key). This script makes both builds ship the same thing.
#
# Usage: scripts/compile-catalog.sh <path/to/Dish_Dish.bundle>
set -euo pipefail

BUNDLE="${1:?usage: compile-catalog.sh <resource bundle>}"
if [ ! -d "$BUNDLE" ]; then
  echo "No resource bundle at $BUNDLE" >&2
  exit 1
fi

CATALOG="$(find "$BUNDLE" -name 'Localizable.xcstrings' -print -quit)"
if [ -n "$CATALOG" ]; then
  xcrun xcstringstool compile "$CATALOG" --output-directory "$(dirname "$CATALOG")"
  rm "$CATALOG"
  echo "Compiled the String Catalog in $BUNDLE"
fi

for language in bs de en es fr pt-BR; do
  if [ -z "$(find "$BUNDLE" -type d -name "$language.lproj" -print -quit)" ]; then
    echo "The $language tables are missing from $BUNDLE; the catalog is not shipping." >&2
    exit 1
  fi
done
