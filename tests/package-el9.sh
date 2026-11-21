#!/bin/bash
# tcm_fcsim DKMS RPM on AlmaLinux 9 (run inside an AlmaLinux 9 kernel guest,
# see make test-rpm; the guest's /usr and /var are overlays, so nothing is
# installed on the host).  Needs dkms, kernel-devel-$(uname -r), targetcli
# installed on the host and the RPM built by make rpm.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

TCLI=/usr/bin/fcsim-targetcli		# the installed tools, not the tree's
CTL=/usr/bin/fcsimctl
T1=21:00:00:00:00:00:00:01
I1=10:00:00:00:c9:00:00:01

RPM=$(ls "$TOP"/rpmbuild/RPMS/noarch/tcm_fcsim-*.rpm | tail -1)

step "install $(basename "$RPM") (dkms builds the module for $(uname -r))"
rpm -i "$RPM"
dkms status | sed 's/^/  /'
modinfo -n tcm_fcsim | sed 's/^/  /'
modinfo -n tcm_fcsim | grep -q "/lib/modules/$(uname -r)/extra/" || fail "module not installed by dkms"

step "modprobe resolves the dependencies; installed tools work"
modprobe tcm_fcsim
lsmod | grep -E "^(tcm_fcsim|target_core_mod|scsi_transport_fc) " | sed 's/^/  /'
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
$TCLI /fcsim create "$(wwpn_naa $T1)" >/dev/null
$TCLI "/fcsim/$(wwpn_naa $T1)/luns" create /backstores/ramdisk/rd0 >/dev/null
$TCLI "/fcsim/$(wwpn_naa $T1)/acls" create "$(wwpn_naa $I1)" >/dev/null
$CTL host create $I1
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "LUN missing"
D=$(disk_of "$H1" rd0)
dd if=/dev/urandom of=/tmp/pat bs=1M count=4 status=none
dd if=/tmp/pat of=/dev/$D bs=1M oflag=direct status=none
cmp /tmp/pat /dev/$D -n $((4 << 20)) || fail "data mismatch"
$CTL status | sed 's/^/  /'

step "remove"
$CTL clear
/usr/bin/fcsim-targetctl clear
rmdir "$LIO/fcsim"
rmmod tcm_fcsim
rpm -e tcm_fcsim
if modinfo tcm_fcsim >/dev/null 2>&1; then fail "module left behind after rpm -e"; fi
splat_check
echo
echo "PASS"
