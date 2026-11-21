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
for t in fcsimctl fcsim-targetcli fcsim-targetctl; do
	ln -s %{_datadir}/%{name}/$t %{buildroot}%{_bindir}/$t
done

%post
dkms add -m %{name} -v %{version} --rpm_safe_upgrade || :
dkms build -m %{name} -v %{version} || :
dkms install -m %{name} -v %{version} --force || :

%preun
dkms remove -m %{name} -v %{version} --all --rpm_safe_upgrade || :

%files
%license LICENSE
%doc README.md docs/design.md
/usr/src/%{name}-%{version}
%{_datadir}/%{name}
%{_bindir}/fcsimctl
%{_bindir}/fcsim-targetcli
%{_bindir}/fcsim-targetctl
