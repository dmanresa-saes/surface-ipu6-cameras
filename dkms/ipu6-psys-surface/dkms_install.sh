#!/bin/bash
# Install the IPU6 PSYS module as DKMS package "ipu6-psys-surface/1.0".
#
# Sources:
#  - github.com/intel/ipu6-drivers (only drivers/media/pci/intel/ipu6/psys/
#    plus its parent directories' headers and include/): the module is
#    prepared for kernel >=6.10 ON TOP of the mainline intel-ipu6 driver
#    (it does not replace the ISYS). Clone it next to this script first:
#        git clone --depth 1 https://github.com/intel/ipu6-drivers.git
#  - mainline-ipu6-headers/: the ~16 .h files of drivers/media/pci/intel/ipu6/
#    from the mainline kernel (the linux-headers package does not ship them)
#    + uapi/linux/ipu-psys.h from Intel's repo. Included in this directory
#    (GPL-2.0, copied from Linux v6.19).
#
# Prerequisite (once per kernel): linux-headers-surface does not ship
# include/generated/autoconf.h; generate it with tools/gen_autoconf.py
# (see the top-level README).
set -e
HERE=$(dirname "$(readlink -f "$0")")
REPO=${REPO:-$HERE/ipu6-drivers}
ML=${ML:-$HERE/mainline-ipu6-headers}
SRC=/usr/src/ipu6-psys-surface-1.0

[ -d "$REPO/drivers/media/pci/intel/ipu6/psys" ] || {
    echo "intel/ipu6-drivers repo not found at $REPO" >&2
    echo "  git clone --depth 1 https://github.com/intel/ipu6-drivers.git $REPO" >&2
    exit 1
}
KVER=$(uname -r)
[ -e "/usr/src/linux-headers-$KVER/include/generated/autoconf.h" ] || {
    echo "include/generated/autoconf.h missing from the $KVER headers;" >&2
    echo "generate it first: sudo python3 tools/gen_autoconf.py \\" >&2
    echo "  /usr/src/linux-headers-$KVER/include/config/auto.conf \\" >&2
    echo "  /usr/src/linux-headers-$KVER/include/generated/autoconf.h" >&2
    exit 1
}

rm -rf "$SRC"
mkdir -p "$SRC/drivers/media/pci/intel/ipu6"
cp "$HERE/dkms.conf" "$HERE/Makefile" "$SRC/"
cp -r "$ML" "$SRC/ml-hdrs"
cp -r "$REPO/include" "$SRC/include"
cp "$REPO"/drivers/media/pci/intel/*.h "$SRC/drivers/media/pci/intel/"
cp "$REPO"/drivers/media/pci/intel/ipu6/*.h "$SRC/drivers/media/pci/intel/ipu6/"
cp -r "$REPO/drivers/media/pci/intel/ipu6/psys" "$SRC/drivers/media/pci/intel/ipu6/"
# in case the repo carries leftovers of a manual build
find "$SRC" -name '*.o' -o -name '*.ko' -o -name '*.mod*' -o -name '.*.cmd' \
    -o -name 'Module.symvers' -o -name 'modules.order' | xargs -r rm -f

dkms remove ipu6-psys-surface/1.0 --all 2>/dev/null || true
dkms add -m ipu6-psys-surface -v 1.0
dkms build -m ipu6-psys-surface -v 1.0
dkms install -m ipu6-psys-surface -v 1.0 --force
dkms status

# Load at boot: the auxiliary:intel_ipu6.psys alias already autoloads the
# module when intel-ipu6 creates the device, but modules-load.d does not hurt
# and covers the aux device appearing before depmod has run.
echo intel-ipu6-psys > /etc/modules-load.d/intel-ipu6-psys.conf
echo "OK: module installed; loads at boot (auxiliary alias + modules-load.d)"
