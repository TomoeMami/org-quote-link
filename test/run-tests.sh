#!/usr/bin/env bash
# Run the org-quote-link ERT test suites in batch mode.
#
#   ./test/run-tests.sh                     # unit + edge tests
#   ./test/run-tests.sh --unit              # unit tests only
#   ./test/run-tests.sh --edge              # edge-case tests only
#   ./test/run-tests.sh --interop           # optional org-transclusion-blocks interop
#
#   EMACS=/path/to/emacs ./test/run-tests.sh
#   EXTRA_LOAD_PATH=/path/a:/path/b ./test/run-tests.sh --interop
#   ./test/run-tests.sh org-quote-link-test-file-heading   # single test
#
# Extra positional arguments are passed to
# `ert-run-tests-batch-and-exit' as the test selector.
# EXTRA_LOAD_PATH is a colon separated list of additional `-L' entries
# (only needed for the optional interop tests, which require
# org-transclusion and org-transclusion-blocks; not a package dependency).

set -euo pipefail

cd "$(dirname "$0")/.."

EMACS="${EMACS:-emacs}"
mode=all
selector=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --unit)        mode=unit;        shift ;;
        --edge)        mode=edge;        shift ;;
        --interop)     mode=interop;     shift ;;
        *)             selector="$1";    shift ;;
    esac
done

case "$mode" in
    unit)        files=(-l test/org-quote-link-test.el) ;;
    edge)        files=(-l test/org-quote-link-edge-test.el) ;;
    interop)     files=(-l test/org-quote-link-interop-test.el) ;;
    *)           files=(-l test/org-quote-link-test.el
                        -l test/org-quote-link-edge-test.el) ;;
esac

extra=()
if [[ -n "${EXTRA_LOAD_PATH:-}" ]]; then
    IFS=':' read -r -a paths <<< "$EXTRA_LOAD_PATH"
    for p in "${paths[@]}"; do
        [[ -n "$p" ]] && extra+=(-L "$p")
    done
fi

if [[ -n "$selector" ]]; then
    exec "$EMACS" -Q -batch -L . "${extra[@]}" "${files[@]}" \
         --eval "(ert-run-tests-batch-and-exit \"$selector\")"
else
    exec "$EMACS" -Q -batch -L . "${extra[@]}" "${files[@]}" \
         -f ert-run-tests-batch-and-exit
fi
