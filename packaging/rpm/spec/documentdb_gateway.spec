%define debug_package %{nil}

Name:           documentdb_gateway
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB Gateway - MongoDB wire protocol for DocumentDB
License:        MIT
URL:            https://github.com/documentdb/documentdb

Requires:       jq

%description
The DocumentDB Gateway provides MongoDB wire protocol compatibility for DocumentDB,
enabling connections from MongoDB clients and drivers.

%pre
getent group documentdb >/dev/null || groupadd -r documentdb
NOLOGIN=$(command -v nologin 2>/dev/null || echo /sbin/nologin)
getent passwd documentdb >/dev/null || useradd -r -g documentdb -d /var/lib/documentdb -s "$NOLOGIN" documentdb
mkdir -p /var/lib/documentdb
chown documentdb:documentdb /var/lib/documentdb

%install
install -Dpm 0755 %{_sourcedir}/documentdb_gateway %{buildroot}/usr/bin/documentdb_gateway
install -Dpm 0755 %{_sourcedir}/documentdb-setup.sh %{buildroot}/usr/bin/documentdb-setup
install -Dpm 0644 %{_sourcedir}/SetupConfiguration.json %{buildroot}/etc/documentdb/SetupConfiguration.json
install -Dpm 0644 %{_sourcedir}/documentdb-postgresql.service %{buildroot}/lib/systemd/system/documentdb-postgresql.service
install -Dpm 0644 %{_sourcedir}/documentdb-gateway.service %{buildroot}/lib/systemd/system/documentdb-gateway.service
install -Dpm 0755 %{_sourcedir}/scripts/documentdb_postgresql_service.sh %{buildroot}/usr/share/documentdb/scripts/documentdb_postgresql_service.sh
install -Dpm 0644 %{_sourcedir}/scripts/utils.sh %{buildroot}/usr/share/documentdb/scripts/utils.sh
install -Dpm 0755 %{_sourcedir}/scripts/start_oss_server.sh %{buildroot}/usr/share/documentdb/scripts/start_oss_server.sh
install -Dpm 0755 %{_sourcedir}/scripts/build_and_start_gateway.sh %{buildroot}/usr/share/documentdb/scripts/build_and_start_gateway.sh
install -Dpm 0755 %{_sourcedir}/scripts/emulator_entrypoint.sh %{buildroot}/usr/share/documentdb/scripts/emulator_entrypoint.sh
install -Dpm 0755 %{_sourcedir}/scripts/init_documentdb_data.sh %{buildroot}/usr/share/documentdb/scripts/init_documentdb_data.sh
install -Dpm 0755 %{_sourcedir}/scripts/setup_psqlrc.sh %{buildroot}/usr/share/documentdb/scripts/setup_psqlrc.sh
install -Dpm 0644 %{_sourcedir}/sample-data/01-users.js %{buildroot}/usr/share/documentdb/sample-data/01-users.js
install -Dpm 0644 %{_sourcedir}/sample-data/02-products.js %{buildroot}/usr/share/documentdb/sample-data/02-products.js
install -Dpm 0644 %{_sourcedir}/sample-data/03-orders.js %{buildroot}/usr/share/documentdb/sample-data/03-orders.js
install -Dpm 0644 %{_sourcedir}/sample-data/04-analytics.js %{buildroot}/usr/share/documentdb/sample-data/04-analytics.js
install -Dpm 0644 %{_sourcedir}/sample-data/README.md %{buildroot}/usr/share/documentdb/sample-data/README.md

%post
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi
echo "DocumentDB Gateway runtime installed."
echo "Choose the PostgreSQL major you want and install the matching DocumentDB extension package before running documentdb-setup."
echo "For example: sudo dnf install postgresql17-documentdb"
echo "Next step:"
echo "  sudo documentdb-setup --username <USER> --password-file <FILE>"

%preun
if command -v systemctl >/dev/null 2>&1; then
    if [ "$1" -eq 0 ]; then
        systemctl stop documentdb-postgresql || true
        systemctl disable documentdb-postgresql || true
        systemctl stop documentdb-gateway || true
        systemctl disable documentdb-gateway || true
    elif [ "$1" -eq 1 ]; then
        systemctl stop documentdb-postgresql || true
        systemctl stop documentdb-gateway || true
    fi
fi

%postun
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

%files
%defattr(-,root,root,-)
/usr/bin/documentdb_gateway
/usr/bin/documentdb-setup
%config(noreplace) /etc/documentdb/SetupConfiguration.json
/lib/systemd/system/documentdb-postgresql.service
/lib/systemd/system/documentdb-gateway.service
/usr/share/documentdb/scripts/*
/usr/share/documentdb/sample-data/*

%changelog
