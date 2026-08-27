#!/bin/bash
# Install the patched ov7251 driver as DKMS package ov7251-surface/1.0.
# Prerequisite on linux-surface kernels: include/generated/autoconf.h
# (see tools/gen_autoconf.py and the README).
set -e
HERE=$(dirname "$(readlink -f "$0")")
SRC=/usr/src/ov7251-surface-1.0
rm -rf "$SRC"; mkdir -p "$SRC"
cp "$HERE"/{ov7251.c,Makefile,dkms.conf} "$SRC/"
dkms remove ov7251-surface/1.0 --all 2>/dev/null || true
dkms add -m ov7251-surface -v 1.0
dkms build -m ov7251-surface -v 1.0
dkms install -m ov7251-surface -v 1.0 --force
dkms status | grep ov7251
