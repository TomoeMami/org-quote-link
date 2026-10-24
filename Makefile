# Makefile for org-quote-link
#
#   make test             run unit + edge-case ERT suites (batch)
#   make test-unit        run only the unit tests
#   make test-edge        run only the edge-case tests
#   make test-interop     run the optional org-transclusion-blocks interop tests
#   make compile          byte-compile the package
#   make clean            remove byte-compiled files

EMACS ?= emacs
PACKAGE = org-quote-link.el
TEST = test/org-quote-link-test.el
TEST_EDGE = test/org-quote-link-edge-test.el
TEST_INTEROP = test/org-quote-link-interop-test.el

.PHONY: test test-unit test-edge test-interop compile clean

# Clean first: loading a .elc compiled by a different Emacs version can
# shadow the source and produce confusing failures.
test: clean
	$(EMACS) -Q -batch -L . -l $(TEST) -l $(TEST_EDGE) \
	         -f ert-run-tests-batch-and-exit

test-unit: clean
	$(EMACS) -Q -batch -L . -l $(TEST) -f ert-run-tests-batch-and-exit

test-edge: clean
	$(EMACS) -Q -batch -L . -l $(TEST_EDGE) -f ert-run-tests-batch-and-exit

# Optional interoperability tests.  They are NOT package dependencies and
# are not run by `make test'; they need org-transclusion and
# org-transclusion-blocks on the load path, e.g.
#   make test-interop EMACS="emacs -L /path/to/org-transclusion ..."
test-interop: clean
	$(EMACS) -Q -batch -L . -l $(TEST_INTEROP) \
	         -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q -batch -L . -f batch-byte-compile $(PACKAGE)

clean:
	rm -f *.elc test/*.elc
