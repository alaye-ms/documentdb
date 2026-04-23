# Auto-detect whether to use the distro's native PostgreSQL (Fedora >=43 ships
# PG 18) or the PGDG repository layout (EL9 and older Fedora).  Callers can
# override with `--define "postgresql_default N"`.
%if 0%{?fedora} >= 43
%{!?postgresql_default:%global postgresql_default 1}
%else
%{!?postgresql_default:%global postgresql_default 0}
%endif

%global sname documentdb
%global pgversion 18

%if %?postgresql_default
%global pg_config   %{_bindir}/pg_config
%global pg_libdir   %{_libdir}/pgsql
%global pg_sharedir %{_datadir}/pgsql
%else
%global pginstdir  /usr/pgsql-%{pgversion}
%global pg_config   %{pginstdir}/bin/pg_config
%global pg_libdir   %{pginstdir}/lib
%global pg_sharedir %{pginstdir}/share
%endif

%global pg_cron_version 1.6.7
%global libbson_version 1.28.0
%global intelmathlib_version 2.0u3-1
%global pcre2_version 10.44

# Debuginfo is disabled: mixed C (PGXS) and Rust (cargo) builds with vendored
# libraries make split-debuginfo unreliable.  Revisit when pgrx gains native
# debuginfo support.  Binaries are stripped by the default %%__os_install_post.
%global debug_package %{nil}

Name:           postgresql%{pgversion}-%{sname}
Version:        0.111.0
Release:        1%{?dist}
Summary:        Document-oriented NoSQL engine for PostgreSQL
License:        MIT
URL:            https://documentdb.io
Source0:        https://github.com/%{sname}/%{sname}/archive/refs/tags/v%{version}.tar.gz#/%{sname}-%{version}.tar.gz
Source1:        https://github.com/mongodb/mongo-c-driver/releases/download/%{libbson_version}/mongo-c-driver-%{libbson_version}.tar.gz
# Generate: git clone --depth 1 -b applied/2.0u3-1 https://git.launchpad.net/ubuntu/+source/intelrdfpmath intelrdfpmath-2.0u3-1 && tar czf intelrdfpmath-2.0u3-1.tar.gz intelrdfpmath-2.0u3-1
Source2:        intelrdfpmath-%{intelmathlib_version}.tar.gz
# Generate: cd pg_documentdb_gw && cargo vendor && tar czf ../documentdb-gateway-vendor.tar.gz vendor/
Source3:        documentdb-gateway-vendor.tar.gz
# Vendored pg_cron source (not in all distro repos; PostgreSQL License)
Source4:        https://github.com/citusdata/pg_cron/archive/refs/tags/v%{pg_cron_version}.tar.gz#/pg_cron-%{pg_cron_version}.tar.gz
# Vendored pcre2 source (EL9 lacks pcre2-static without CRB)
Source5:        https://github.com/PCRE2Project/pcre2/releases/download/pcre2-%{pcre2_version}/pcre2-%{pcre2_version}.tar.gz

%if %?postgresql_default
%global pkgname %{sname}
%package -n %{pkgname}
Summary: Document-oriented NoSQL engine for PostgreSQL
%else
%global pkgname %name
%endif

ExclusiveArch:  x86_64 aarch64

BuildRequires: gcc
BuildRequires: make
BuildRequires: cmake
BuildRequires: pkgconfig
%if %?postgresql_default
BuildRequires: postgresql-server-devel
%else
# PGDG ships the PostgreSQL server headers in postgresql<NN>-devel on EL,
# not postgresql<NN>-server-devel (the latter does not exist in pgdg repos).
BuildRequires: postgresql%{pgversion}-devel
%endif
BuildRequires: pkgconfig(icu-uc)
BuildRequires: pkgconfig(icu-i18n)
BuildRequires: pkgconfig(krb5)
BuildRequires: pkgconfig(libpcre2-8)
BuildRequires: pkgconfig(openssl)
BuildRequires: rust
BuildRequires: cargo
BuildRequires: cargo-rpm-macros
BuildRequires: systemd-rpm-macros
BuildRequires: pkgconfig(libsasl2)
BuildRequires: pkgconfig(snappy)
BuildRequires: pkgconfig(zlib)
BuildRequires: pkgconfig(libcurl)
BuildRequires: pkgconfig(uuid)
BuildRequires: pkgconfig(liblz4)
# bzip2-devel does not ship a .pc file; kept as a package name dependency.
BuildRequires: bzip2-devel

# ---------------------------------------------------------------------------
# Runtime dependencies
# ---------------------------------------------------------------------------
%if %?postgresql_default
Requires:       postgresql-server
Requires:       postgresql-contrib
Requires:       pgvector
Requires:       postgis
%else
Requires:       postgresql%{pgversion}-server
Requires:       pgvector_%{pgversion}
Requires:       pg_cron_%{pgversion}
Requires:       postgis36_%{pgversion}
%endif

Provides:       bundled(libbson) = %{libbson_version}
Provides:       bundled(intelmathlib) = %{intelmathlib_version}
%if %?postgresql_default
Provides:       bundled(pg_cron) = %{pg_cron_version}
%else 
Provides:       bundled(pcre2) = %{pcre2_version}
%endif

%description
DocumentDB is the open-source engine powering Azure DocumentDB.
It offers a native implementation of document-oriented NoSQL database,
enabling seamless CRUD operations on BSON data types within a PostgreSQL
framework.

%if %?postgresql_default
# On Fedora native builds, %%{pkgname} is a distinct subpackage (%%{sname});
# on PGDG builds %%{pkgname} == %%{name} so the main %%description above
# already applies and a second block would be a duplicate.
%description -n %{pkgname}
DocumentDB is the open-source engine powering Azure DocumentDB.
It offers a native implementation of document-oriented NoSQL database,
enabling seamless CRUD operations on BSON data types within a PostgreSQL
framework.
%endif

# ---------------------------------------------------------------------------
# Subpackage: documentdb-gateway
# ---------------------------------------------------------------------------
%package -n documentdb-gateway
Summary:        MongoDB wire protocol proxy for PostgreSQL
Requires:       jq
Requires(pre):  shadow-utils
%{?systemd_requires}
BuildRequires:  systemd

%description -n documentdb-gateway
The DocumentDB Gateway is a Rust-based proxy that implements the MongoDB wire
protocol and translates requests to the DocumentDB PostgreSQL extensions.
This package ships the gateway binary, systemd units, helper scripts, default
configuration, and sample data used by packaged installations.

%pre -n documentdb-gateway
getent group documentdb >/dev/null || groupadd -r documentdb
getent passwd documentdb >/dev/null || \
    useradd -r -g documentdb -d /var/lib/documentdb -s /sbin/nologin \
            -c "DocumentDB gateway service account" documentdb
exit 0

%post -n documentdb-gateway
%systemd_post documentdb-postgresql.service documentdb-gateway.service

%preun -n documentdb-gateway
%systemd_preun documentdb-postgresql.service documentdb-gateway.service

%postun -n documentdb-gateway
%systemd_postun_with_restart documentdb-postgresql.service documentdb-gateway.service

# ---------------------------------------------------------------------------
# Subpackage: documentdb-server (meta-package)
# ---------------------------------------------------------------------------
%package -n documentdb-server
Summary:        Complete installation meta-package
Requires:       %{name} = %{version}-%{release}
Requires:       documentdb-gateway = %{version}-%{release}
Requires:       postgresql%{pgversion}-server

%description -n documentdb-server
Meta-package that pulls in all DocumentDB components: the PostgreSQL extensions,
the gateway binary, and the PostgreSQL server.

%ldconfig_scriptlets

# PGDG installs to /usr/pgsql-18/lib which triggers the default RPATH check.
# Native PG paths don't have this issue.
%if !0%{?postgresql_default}
%global __brp_check_rpaths QA_RPATHS=0x0002 /usr/lib/rpm/check-rpaths
%endif

# ===========================================================================
%prep
# Source tarball is always named documentdb-VERSION regardless of %{name}
%setup -q -n %{sname}-%{version}

# Extract vendored dependency sources inside the main source tree
tar xf %{SOURCE1}
tar xf %{SOURCE2}


%if %?postgresql_default
# Native PG: extract vendored pg_cron (not in distro repos)
tar xf %{SOURCE4}
%else 
# PGDG: extract vendored pcre2 (CRB not available in mock)
tar xf %{SOURCE5}
%endif

# Set up Cargo vendored dependencies for the gateway build
pushd pg_documentdb_gw
tar xf %{SOURCE3}
mkdir -p .cargo
cat > .cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF
popd

# Remove internal/ (proprietary pg_documentdb_distributed) from build targets
sed -i '/internal/d' Makefile

# Strip -Werror from all Makefiles to avoid build failures with newer GCC.
# This must be done here rather than via a PG_CFLAGS command-line override because
# sub-Makefiles append to PG_CFLAGS (e.g. -DCROARING_ATOMIC_IMPL=3 in pg_documentdb/).
sed -i 's/-Werror //g' Makefile.cflags pg_documentdb_extended_rum/core/Makefile

%if !%?postgresql_default
# Polyfill str::floor_char_boundary() which is only stable since Rust 1.91.
# EL9 ships Rust 1.88, so replace with an equivalent using is_char_boundary()
# (stable since Rust 1.0). Only apply when the system Rust is too old.
RUST_MINOR=$(rustc --version | sed -n 's/^rustc [0-9]\+\.\([0-9]\+\)\..*/\1/p')
if [ "${RUST_MINOR:-0}" -lt 91 ]; then
    sed -i 's|command_str\.floor_char_boundary(MAX_EXPLAIN_BSON_COMMAND_LENGTH)|{ let mut i = MAX_EXPLAIN_BSON_COMMAND_LENGTH.min(command_str.len()); while i > 0 \&\& !command_str.is_char_boundary(i) { i -= 1; } i }|' \
        pg_documentdb_gw/documentdb_gateway_core/src/explain/mod.rs
fi
%endif

# ===========================================================================
%build
_vendored=$(pwd)/_vendored
mkdir -p ${_vendored}/lib/pkgconfig

# ---- 1. Build vendored libbson from mongo-c-driver ----
mkdir -p mongo-c-driver-%{libbson_version}/build
pushd mongo-c-driver-%{libbson_version}/build
%{__cmake} \
    -DENABLE_MONGOC=ON \
    -DMONGOC_ENABLE_ICU=OFF \
    -DENABLE_ICU=OFF \
    -DCMAKE_C_FLAGS="-fPIC -g" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=${_vendored} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    ..
%{__make} %{?_smp_mflags} install
popd

# ---- 2. Build vendored Intel Decimal Math Library ----
pushd intelrdfpmath-%{intelmathlib_version}/LIBRARY
%{__make} %{?_smp_mflags} _CFLAGS_OPT=-fPIC CC=gcc \
    CALL_BY_REF=0 GLOBAL_RND=0 GLOBAL_FLAGS=0 UNCHANGED_BINARY_FLAGS=0
popd

# Create intelmathlib pkg-config file pointing at the source build tree
cat > ${_vendored}/lib/pkgconfig/intelmathlib.pc << EOF
prefix=$(pwd)/intelrdfpmath-%{intelmathlib_version}
libdir=\${prefix}/LIBRARY
includedir=\${prefix}/LIBRARY/src

Name: intelmathlib
Description: Intel Decimal Floating point math library
Version: 2.0 Update 2
Cflags: -I\${includedir}
Libs: -L\${libdir} -lbid
EOF

%if !%?postgresql_default
# ---- 3. Build vendored pcre2 static library (PGDG: avoids pcre2-static dep) ----
mkdir -p pcre2-%{pcre2_version}/build
pushd pcre2-%{pcre2_version}/build
%{__cmake} \
    -DCMAKE_C_FLAGS="-fPIC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=${_vendored} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF \
    -DPCRE2_BUILD_PCRE2_8=ON \
    -DPCRE2_BUILD_PCRE2_16=OFF \
    -DPCRE2_BUILD_PCRE2_32=OFF \
    -DPCRE2_BUILD_PCRE2GREP=OFF \
    -DPCRE2_BUILD_TESTS=OFF \
    ..
%{__make} %{?_smp_mflags} install
popd
%endif

# ---- 4. Build C PostgreSQL extensions ----
# Disable LLVM/JIT bitcode: we don't ship bitcode (removed in the install stage).
export PKG_CONFIG_PATH=${_vendored}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}
%{__make} %{?_smp_mflags} \
    PG_CONFIG=%{pg_config} \
    with_llvm=no

%if %?postgresql_default
# ---- 4b. Build vendored pg_cron (native PG only) ----
pushd pg_cron-%{pg_cron_version}
%{__make} %{?_smp_mflags} PG_CONFIG=%{pg_config} with_llvm=no
popd
%endif

# ---- 5. Build gateway binary ----
cd pg_documentdb_gw
cargo build --release
cd ..

# ===========================================================================
%install
_vendored=$(pwd)/_vendored
export PKG_CONFIG_PATH=${_vendored}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}

# ---- Install C extensions via PGXS ----
%{__make} install DESTDIR=%{buildroot} \
    PG_CONFIG=%{pg_config} \
    with_llvm=no

# Remove LLVM/JIT bitcode directory
rm -rf %{buildroot}%{pg_libdir}/bitcode

%if %?postgresql_default
# ---- Install vendored pg_cron (native PG only) ----
pushd pg_cron-%{pg_cron_version}
%{__make} install DESTDIR=%{buildroot} PG_CONFIG=%{pg_config}
popd
%endif

# ---- Bundle vendored libbson shared libraries ----
mkdir -p %{buildroot}%{_libdir}
cp    ${_vendored}/lib/libbson-1.0.so.0.0.0   %{buildroot}%{_libdir}/libbson-1.0.so.0.0.0
cp -P ${_vendored}/lib/libbson-1.0.so.0       %{buildroot}%{_libdir}/libbson-1.0.so.0
cp -P ${_vendored}/lib/libbson-1.0.so         %{buildroot}%{_libdir}/libbson-1.0.so

# ---- Bundle Intel Decimal Math Library static lib ----
mkdir -p %{buildroot}%{_libdir}/intelmathlib/LIBRARY
cp intelrdfpmath-%{intelmathlib_version}/LIBRARY/libbid.a \
   %{buildroot}%{_libdir}/intelmathlib/LIBRARY/

# ---- Install gateway runtime (binary, setup script, config, systemd, helpers, samples) ----
install -D -m 0755 pg_documentdb_gw/target/release/documentdb_gateway \
    %{buildroot}%{_bindir}/documentdb_gateway
install -D -m 0755 documentdb-local/scripts/documentdb-setup.sh \
    %{buildroot}%{_bindir}/documentdb-setup
install -D -m 0644 pg_documentdb_gw/SetupConfiguration.json \
    %{buildroot}%{_sysconfdir}/documentdb/SetupConfiguration.json
install -D -m 0644 packaging/gateway/systemd/documentdb-postgresql.service \
    %{buildroot}%{_unitdir}/documentdb-postgresql.service
install -D -m 0644 packaging/gateway/systemd/documentdb-gateway.service \
    %{buildroot}%{_unitdir}/documentdb-gateway.service
install -D -m 0755 documentdb-local/scripts/documentdb_postgresql_service.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/documentdb_postgresql_service.sh
install -D -m 0644 scripts/utils.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/utils.sh
install -D -m 0755 scripts/start_oss_server.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/start_oss_server.sh
install -D -m 0755 scripts/build_and_start_gateway.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/build_and_start_gateway.sh
install -D -m 0755 documentdb-local/scripts/emulator_entrypoint.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/emulator_entrypoint.sh
install -D -m 0755 documentdb-local/scripts/init_documentdb_data.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/init_documentdb_data.sh
install -D -m 0755 scripts/setup_psqlrc.sh \
    %{buildroot}%{_datadir}/documentdb/scripts/setup_psqlrc.sh
for f in documentdb-local/sample-data/*.js documentdb-local/sample-data/README.md; do
    install -D -m 0644 "$f" "%{buildroot}%{_datadir}/documentdb/sample-data/$(basename "$f")"
done

# ---- Bundle source code for make check ----
mkdir -p %{buildroot}/usr/src/documentdb
cp -r . %{buildroot}/usr/src/documentdb/
# Clean up build artifacts and vendored build trees from the source copy
find %{buildroot}/usr/src/documentdb -name "*.o" -delete
find %{buildroot}/usr/src/documentdb -name "*.so" -delete
find %{buildroot}/usr/src/documentdb -name "*.bc" -delete
rm -rf %{buildroot}/usr/src/documentdb/.git*
rm -rf %{buildroot}/usr/src/documentdb/build
rm -rf %{buildroot}/usr/src/documentdb/_vendored
rm -rf %{buildroot}/usr/src/documentdb/mongo-c-driver-%{libbson_version}
rm -rf %{buildroot}/usr/src/documentdb/intelrdfpmath-%{intelmathlib_version}
rm -rf %{buildroot}/usr/src/documentdb/pg_documentdb_gw/target
rm -rf %{buildroot}/usr/src/documentdb/pg_documentdb_gw/vendor
%if %?postgresql_default
rm -rf %{buildroot}/usr/src/documentdb/pg_cron-%{pg_cron_version}
%else
rm -rf %{buildroot}/usr/src/documentdb/pcre2-%{pcre2_version}
%endif

# Ensure extension shared objects are marked as executable ELF files.
chmod 0755 %{buildroot}%{pg_libdir}/*.so
chmod 0755 %{buildroot}%{_libdir}/libbson-1.0.so.0.0.0

# ===========================================================================
%files
%license LICENSE NOTICE licenses/
%doc README.md CHANGELOG.md
%{pg_libdir}/*.so
%{pg_sharedir}/extension/*.control
%{pg_sharedir}/extension/*.sql
/usr/src/documentdb
%{_libdir}/intelmathlib/LIBRARY/libbid.a
%{_libdir}/libbson-1.0.so
%{_libdir}/libbson-1.0.so.0
%{_libdir}/libbson-1.0.so.0.0.0

%files -n documentdb-gateway
%license LICENSE NOTICE
%{_bindir}/documentdb_gateway
%{_bindir}/documentdb-setup
%dir %{_sysconfdir}/documentdb
%config(noreplace) %{_sysconfdir}/documentdb/SetupConfiguration.json
%{_unitdir}/documentdb-postgresql.service
%{_unitdir}/documentdb-gateway.service
%dir %{_datadir}/documentdb
%dir %{_datadir}/documentdb/scripts
%{_datadir}/documentdb/scripts/documentdb_postgresql_service.sh
%{_datadir}/documentdb/scripts/utils.sh
%{_datadir}/documentdb/scripts/start_oss_server.sh
%{_datadir}/documentdb/scripts/build_and_start_gateway.sh
%{_datadir}/documentdb/scripts/emulator_entrypoint.sh
%{_datadir}/documentdb/scripts/init_documentdb_data.sh
%{_datadir}/documentdb/scripts/setup_psqlrc.sh
%dir %{_datadir}/documentdb/sample-data
%{_datadir}/documentdb/sample-data/*.js
%{_datadir}/documentdb/sample-data/README.md

%files -n documentdb-server
%license LICENSE NOTICE

# ===========================================================================
%changelog
* Mon Mar 09 2026 Shuai Tian <shuaitian@microsoft.com> - 0.111.0-1
- Update to version 0.111.0

* Fri Aug 29 2025 Shuai Tian <shuaitian@microsoft.com> - 0.106-0
- Add internal extension that provides extensions to the `rum` index. *[Feature]*
- Enable let support for update queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
- Enable let support for findAndModify queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
- Add internal extension that provides extensions to the `rum` index. *[Feature]*
- Optimized query for `usersInfo` command.
- Support collation with `delete` *[Feature]*. Requires `EnableCollation` to be `on`.
- Support for index hints for find/aggregate/count/distinct *[Feature]*
- Support `createRole` command *[Feature]*
- Add schema changes for Role CRUD APIs *[Feature]*
- Add support for using EntraId tokens via Plain Auth

* Mon Jul 28 2025 Shuai Tian <shuaitian@microsoft.com> - 0.105-0
- Support `$bucketAuto` aggregation stage, with granularity types: `POWERSOF2`, `1-2-5`, `R5`, `R10`, `R20`, `R40`, `R80`, `E6`, `E12`, `E24`, `E48`, `E96`, `E192` *[Feature]*
- Support `conectionStatus` command *[Feature]*.

* Mon Jun 09 2025 Shuai Tian <shuaitian@microsoft.com> - 0.104-0
- Add string case support for `$toDate` operator
- Support `sort` with collation in runtime*[Feature]*
- Support collation with `$indexOfArray` aggregation operator. *[Feature]*
- Support collation with arrays and objects comparisons *[Feature]*
- Support background index builds *[Bugfix]* (#36)
- Enable user CRUD by default *[Feature]*
- Enable let support for delete queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
- Enable rum_enable_index_scan as default on *[Perf]*
- Add public `documentdb-local` Docker image with gateway to GHCR
- Support `compact` command *[Feature]*. Requires `documentdb.enablecompact` GUC to be `on`.
- Enable role privileges for `usersInfo` command *[Feature]* 

* Fri May 09 2025 Shuai Tian <shuaitian@microsoft.com> - 0.103-0
- Support collation with aggregation and find on sharded collections *[Feature]*
- Support `$convert` on `binData` to `binData`, `string` to `binData` and `binData` to `string` (except with `format: auto`) *[Feature]*
- Fix list_databases for databases with size > 2 GB *[Bugfix]* (#119)
- Support half-precision vector indexing, vectors can have up to 4,000 dimensions *[Feature]*
- Support ARM64 architecture when building docker container *[Preview]*
- Support collation with `$documents` and `$replaceWith` stage of the aggregation pipeline *[Feature]*
- Push pg_documentdb_gw for documentdb connections *[Feature]*

* Wed Mar 26 2025 Shuai Tian <shuaitian@microsoft.com> - 0.102-0
- Support index pushdown for vector search queries *[Bugfix]*
- Support exact search for vector search queries *[Feature]*
- Inline $match with let in $lookup pipelines as JOIN Filter *[Perf]*
- Support TTL indexes *[Bugfix]* (#34)
- Support joining between postgres and documentdb tables *[Feature]* (#61)
- Support current_op command *[Feature]* (#59)
- Support for list_databases command *[Feature]* (#45)
- Disable analyze statistics for unique index uuid columns which improves resource usage *[Perf]*
- Support collation with `$expr`, `$in`, `$cmp`, `$eq`, `$ne`, `$lt`, `$lte`, `$gt`, `$gte` comparison operators (Opt-in) *[Feature]*
- Support collation in `find`, aggregation `$project`, `$redact`, `$set`, `$addFields`, `$replaceRoot` stages (Opt-in) *[Feature]*
- Support collation with `$setEquals`, `$setUnion`, `$setIntersection`, `$setDifference`, `$setIsSubset` in the aggregation pipeline (Opt-in) *[Feature]*
- Support unique index truncation by default with new operator class *[Feature]*
- Top level aggregate command `let` variables support for `$geoNear` stage *[Feature]*
- Enable Backend Command support for Statement Timeout *[Feature]*
- Support type aggregation operator `$toUUID`. *[Feature]*
- Support Partial filter pushdown for `$in` predicates *[Perf]*
- Support the $dateFromString operator with full functionality *[Feature]*
- Support extended syntax for `$getField` aggregation operator. Now the value of 'field' could be an expression that resolves to a string. *[Feature]*

* Wed Feb 12 2025 Shuai Tian <shuaitian@microsoft.com> - 0.101-0
- Push $graphlookup recursive CTE JOIN filters to index *[Perf]*
- Build pg_documentdb for PostgreSQL 17 *[Infra]* (#13)
- Enable support of currentOp aggregation stage, along with collstats, dbstats, and indexStats *[Commands]* (#52)
- Allow inlining $unwind with $lookup with `preserveNullAndEmptyArrays` *[Perf]*
- Skip loading documents if group expression is constant *[Perf]*
- Fix Merge stage not outputing to target collection *[Bugfix]* (#20)

* Thu Jan 23 2025 Shuai Tian <shuaitian@microsoft.com> - 0.100-0
- Initial Release