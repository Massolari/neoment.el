# Makefile for neoment.el

EMACS ?= emacs
DEPS_DIR := $(CURDIR)/.deps
PACKAGE_INIT := --eval "(progn (require 'package) (setq package-user-dir \"$(DEPS_DIR)\") (package-initialize))"
SRCS := $(filter-out %-autoloads.el %-pkg.el,$(wildcard neoment*.el))
TESTS := $(sort $(wildcard test/neoment-*-test.el))

.PHONY: all deps test compile lint clean

all: compile lint test

deps:
	$(EMACS) -Q --batch \
	  --eval "(progn (require 'package) (setq package-user-dir \"$(DEPS_DIR)\") \
	    (add-to-list 'package-archives '(\"melpa\" . \"https://melpa.org/packages/\") t) \
	    (package-initialize) (package-refresh-contents) \
	    (dolist (p '(plz package-lint)) (unless (package-installed-p p) (package-install p))))"

test:
	$(EMACS) -Q --batch $(PACKAGE_INIT) -L . -L test \
	  -l test/test-helper.el $(patsubst %,-l %,$(TESTS)) \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch $(PACKAGE_INIT) -L . \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  -f batch-byte-compile $(SRCS)
	rm -f neoment*.elc

lint:
	$(EMACS) -Q --batch $(PACKAGE_INIT) -L . -l test/lint.el $(SRCS)

clean:
	rm -f neoment*.elc test/*.elc
