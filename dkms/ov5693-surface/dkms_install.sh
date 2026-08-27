#!/bin/bash
# Install the patched ov5693 driver as DKMS package ov5693-surface/1.0.
# Prerequisite on linux-surface kernels: include/generated/autoconf.h
# (see tools/gen_autoconf.py and the README).
set -e
HERE=$(dirname "$(readlink -f "$0")")
SRC=/usr/src/ov5693-surface-1.0
rm -rf "$SRC"; mkdir -p "$SRC"
cp "$HERE"/{ov5693.c,Makefile,dkms.conf} "$SRC/"
dkms remove ov5693-surface/1.0 --all 2>/dev/null || true
dkms add -m ov5693-surface -v 1.0
dkms build -m ov5693-surface -v 1.0
dkms install -m ov5693-surface -v 1.0 --force
dkms status | grep ov5693
