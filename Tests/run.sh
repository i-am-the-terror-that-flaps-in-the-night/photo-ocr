#!/bin/bash
# Runs the OCR core against the fixture images. Run ./build.sh first.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$DIR/build/ocr_cli"
FIX="$DIR/Tests/fixtures"
[ -x "$CLI" ] || { echo "build/ocr_cli not found; run ./build.sh first" >&2; exit 2; }

failures=0
for name in sample.png sample.heic sample_rotated.jpg sample_rotated_untagged.png; do
    if "$CLI" "$FIX/$name" | diff - "$FIX/expected.txt" >/dev/null; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"; failures=$((failures + 1))
    fi
done

if [ -z "$("$CLI" "$FIX/blank.png" | tr -d '[:space:]')" ]; then
    echo "PASS  blank.png (no text)"
else
    echo "FAIL  blank.png"; failures=$((failures + 1))
fi

if "$CLI" "$FIX/not_image.txt" >/dev/null 2>&1; then
    echo "FAIL  not_image.txt (should be rejected)"; failures=$((failures + 1))
else
    echo "PASS  not_image.txt (rejected)"
fi

# Clean-up: misread words are repaired, stray marks at line ends are removed,
# and ambiguous or correct words are left alone.
if "$CLI" --clean-up < "$FIX/cleanup_input.txt" | diff - "$FIX/cleanup_expected.txt" >/dev/null; then
    echo "PASS  clean-up"
else
    echo "FAIL  clean-up"; failures=$((failures + 1))
    "$CLI" --clean-up < "$FIX/cleanup_input.txt" | diff - "$FIX/cleanup_expected.txt" | sed 's/^/      /'
fi

# Clean-up must leave correct text alone: each line of cleanup_keep.txt is
# cleaned on its own and must come back unchanged.
keep_failures=0
while IFS= read -r line; do
    out="$(printf '%s' "$line" | "$CLI" --clean-up)"
    if [ "$out" != "$line" ]; then
        echo "      changed: [$line] -> [$out]"; keep_failures=$((keep_failures + 1))
    fi
done < "$FIX/cleanup_keep.txt"
if [ "$keep_failures" -eq 0 ]; then
    echo "PASS  clean-up leaves correct text alone"
else
    echo "FAIL  clean-up changed $keep_failures correct line(s)"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "All tests passed." || { echo "$failures test(s) failed."; exit 1; }
