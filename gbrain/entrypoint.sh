#!/bin/sh
set -eu

: "${GBRAIN_HOME:=/var/lib/gbrain/home}"
mkdir -p "$GBRAIN_HOME"

# Invoke the checked-out CLI directly rather than through a package script.
# GBrain/PGLite may still leave a stale serve lock after a stopped HTTP service;
# the test runner preserves and archives that derived lock before a restart.
exec bun /opt/gbrain/src/cli.ts "$@"
