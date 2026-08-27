#!/bin/bash
# Install the patched intel_skl_int3472_discrete as DKMS package
# int3472-surface/1.0 (sensor power/regulator glue for the IR and rear
# cameras). Prerequisite on linux-surface kernels:
# include/generated/autoconf.h (see tools/gen_autoconf.py and the README).
set -e
HERE=$(dirname "$(readlink -f "$0")")
SRC=/usr/src/int3472-surface-1.0
rm -rf "$SRC"; mkdir -p "$SRC"
cp "$HERE"/{discrete.c,discrete_quirks.c,clk_and_regulator.c,led.c,Kbuild,Makefile,dkms.conf} "$SRC/"
dkms remove int3472-surface/1.0 --all 2>/dev/null || true
dkms add -m int3472-surface -v 1.0
dkms build -m int3472-surface -v 1.0
dkms install -m int3472-surface -v 1.0 --force
dkms status | grep int3472
