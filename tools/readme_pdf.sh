#!/bin/sh
# README.md → docs/readme-body.typ (pandoc) → docs/MotionDraw.pdf (typst).
# Run by the pre-commit hook whenever README.md is staged, or by hand.
set -e
cd "$(dirname "$0")/.."
pandoc README.md -t typst -o docs/readme-body.typ
# pandoc sizes table columns from the markdown dashes; let the last column
# take the rest of the line instead.
sed -i '' -E -e 's/columns: \([0-9.%, ]+\),/columns: (auto, auto, 1fr),/' \
  -e 's/align: \((auto,)+\),/align: left + top,/' docs/readme-body.typ
typst compile --font-path assets/fonts docs/readme.typ docs/MotionDraw.pdf
echo "docs/MotionDraw.pdf updated"
