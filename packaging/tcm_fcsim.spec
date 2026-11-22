# DKMS package of tcm_fcsim for AlmaLinux 9: the module source under
# /usr/src (built by dkms for each installed kernel) plus the tools.
Name:		tcm_fcsim
Version:	%{fcsim_version}
Release:	1%{?dist}
Summary:	Software-only Fibre Channel storage emulation for LIO (DKMS)
License:	GPL-2.0-only
Source0:	%{name}-%{version}.tar.gz
BuildArch:	noarch
Requires:	dkms
Requires:	kernel-devel
Requires:	python3-rtslib
Requires:	targetcli

%description
A kernel module that makes an FC HBA (fc_host, fc_remote_ports,
fc_transport) and LIO target ports (fabric "fcsim") appear without FC
hardware, connected by a virtual fabric.  Includes fcsimctl and the
targetcli / targetctl wrappers.

%prep
%autosetup

%build

%install
mkdir -p %{buildroot}/usr/src/%{name}-%{version}/src
install -m 0644 src/*.c src/*.h src/Kbuild %{buildroot}/usr/src/%{name}-%{version}/src/
sed 's/@VERSION@/%{version}/' packaging/dkms.conf > %{buildroot}/usr/src/%{name}-%{version}/dkms.conf
mkdir -p %{buildroot}%{_datadir}/%{name} %{buildroot}%{_bindir}
install -m 0755 tools/fcsimctl tools/fcsim-targetcli %{buildroot}%{_datadir}/%{name}/
install -m 0644 tools/fcsim_rtslib.py %{buildroot}%{_datadir}/%{name}/
ln -s fcsim-targetcli %{buildroot}%{_datadir}/%{name}/fcsim-targetctl
# Every tool in %{_datadir}/%{name} gets a link in %{_bindir} (fcsim*).
for t in %{buildroot}%{_datadir}/%{name}/fcsim*; do
	[ "${t%.py}" = "$t" ] || continue	# not the rtslib module
	ln -s %{_datadir}/%{name}/${t##*/} %{buildroot}%{_bindir}/${t##*/}
done

%post
# A failed build must not fail the installation, but it must be visible:
# typically kernel-devel for the running kernel is missing.
fail() {
	echo "%{name}: dkms $1 failed for kernel $(uname -r); the module is not installed." >&2
	echo "%{name}: is kernel-devel-$(uname -r) installed?  See 'dkms status' and" \
		"/var/lib/dkms/%{name}/%{version}/build/make.log" >&2
}
dkms add -m %{name} -v %{version} --rpm_safe_upgrade >/dev/null 2>&1 ||
	dkms status -m %{name} -v %{version} | grep -q . || fail add
if ! dkms build -m %{name} -v %{version}; then
	fail build
elif ! dkms install -m %{name} -v %{version} --force; then
	fail install
fi
:

%preun
dkms remove -m %{name} -v %{version} --all --rpm_safe_upgrade || :

%files
%license LICENSE
%doc README.md docs/design.md docs/stage3-plan.md
/usr/src/%{name}-%{version}
%{_datadir}/%{name}
%{_bindir}/fcsim*
