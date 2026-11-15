#!/bin/bash
# Builds one NexDB server program for this Mac's chip, for macOS 13 and newer.
#   scripts/macos-servers/build.sh <id> <version>
# ids: apache nginx php mysql postgres redis node mailpit
# Output: out/<id>-<version>-macos-<x64|arm64>.tar.xz and .sha256 (see common.sh).
source "$(cd "$(dirname "$0")" && pwd)/common.sh"

id="${1:?id}"; version="${2:?version}"
line="$(echo "$version" | cut -d. -f1-2)"
stage="$WORK/stage/$id-$version"                      # the install prefix while building
rm -rf "$stage"; mkdir -p "$stage"

build_redis() {
  deps_openssl
  local src; src="$(unpack "$(fetch "https://download.redis.io/releases/redis-$version.tar.gz")")"
  # Core server only: Redis 8's optional modules (search, JSON, ...) need extra toolchains.
  (cd "$src" && make -C src -j"$JOBS" all BUILD_TLS=yes OPENSSL_PREFIX="$DEPS" MALLOC=libc)
  mkdir -p "$stage/bin"
  cp "$src"/src/redis-server "$src"/src/redis-cli "$src"/src/redis-benchmark "$stage/bin/"
  cp "$src/redis.conf" "$stage/"
}

build_postgres() {
  deps_openssl_shared
  local src; src="$(unpack "$(fetch "https://ftp.postgresql.org/pub/source/v$version/postgresql-$version.tar.bz2")")"
  (cd "$src" && ./configure --prefix="$stage" --with-openssl --without-icu --without-readline \
      CPPFLAGS="-I$DEPS_SHARED/include" LDFLAGS="-L$DEPS_SHARED/lib" \
    && make -j"$JOBS" && make install && make -C contrib -j"$JOBS" install)
  bundle_openssl "$stage/lib"
  relocate "$stage" "$stage"
}

build_apache() {
  deps_openssl; deps_pcre2
  local src apr aprutil
  src="$(unpack "$(fetch "https://archive.apache.org/dist/httpd/httpd-$version.tar.bz2")")"
  apr="$(unpack "$(fetch "https://archive.apache.org/dist/apr/apr-${APR_VERSION:-1.7.6}.tar.bz2")")"
  aprutil="$(unpack "$(fetch "https://archive.apache.org/dist/apr/apr-util-${APRUTIL_VERSION:-1.6.3}.tar.bz2")")"
  rm -rf "$src/srclib/apr" "$src/srclib/apr-util"
  mv "$apr" "$src/srclib/apr"; mv "$aprutil" "$src/srclib/apr-util"
  (cd "$src" && ./configure --prefix="$stage" --with-included-apr --with-mpm=event \
      --enable-mods-shared=reallyall --enable-ssl --with-ssl="$DEPS" \
      --with-pcre="$DEPS/bin/pcre2-config" --disable-http2 --disable-proxy-http2 --disable-brotli \
      --without-odbc --without-pgsql --without-mysql --without-oracle --without-freetds \
    && make -j"$JOBS" && make install)
  rm -rf "$stage/manual" "$stage/htdocs"/* "$stage/cgi-bin"/*
  relocate "$stage" "$stage"
}

build_nginx() {
  local src ossl pcre
  src="$(unpack "$(fetch "https://nginx.org/download/nginx-$version.tar.gz")")"
  ossl="$(unpack "$(fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz")")"
  pcre="$(unpack "$(fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.bz2")")"
  (cd "$src" && ./configure --prefix=. --sbin-path=nginx --conf-path=conf/nginx.conf \
      --error-log-path=logs/error.log --http-log-path=logs/access.log --pid-path=logs/nginx.pid \
      --with-http_ssl_module --with-http_v2_module --with-http_realip_module --with-http_gzip_static_module \
      --with-openssl="$ossl" --with-openssl-opt="no-shared no-tests" --with-pcre="$pcre" --with-pcre-jit \
      --with-cc-opt="$CFLAGS" --with-ld-opt="$LDFLAGS" \
    && make -j"$JOBS")
  mkdir -p "$stage/conf" "$stage/logs" "$stage/temp"
  cp "$src/objs/nginx" "$stage/"
  cp -R "$src/conf/." "$stage/conf/"
}

# PHP with every extension NexDB offers built in (static-php-cli). There is no ext folder:
# NexDB's php.ini must not list extension= lines on macOS.
PHP_EXTENSIONS="${PHP_EXTENSIONS:-bcmath,calendar,ctype,curl,dom,exif,fileinfo,filter,ftp,gd,iconv,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,pgsql,phar,posix,redis,session,simplexml,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib}"
build_php() {
  local spc_arch spc_dir="$WORK/spc"
  spc_arch="$([ "$ARCH" = arm64 ] && echo aarch64 || echo x86_64)"
  mkdir -p "$spc_dir"
  if [ ! -x "$spc_dir/spc" ]; then
    tar -xzf "$(fetch "https://github.com/crazywhalecc/static-php-cli/releases/latest/download/spc-macos-$spc_arch.tar.gz" "$WORK/src/spc-$spc_arch.tar.gz")" -C "$spc_dir"
    chmod +x "$spc_dir/spc"
  fi
  rm -rf "$spc_dir/buildroot" "$spc_dir/source/php-src"
  # static-php-cli sets its own compiler flags; ours would be mixed into every library it builds.
  # On failure its own log has the real reason, so the end of it is printed.
  (cd "$spc_dir" && unset CFLAGS CXXFLAGS LDFLAGS && ./spc doctor --auto-fix && ./spc download --with-php="$version" --for-extensions="$PHP_EXTENSIONS" --prefer-pre-built \
    && ./spc build "$PHP_EXTENSIONS" --build-cli --build-fpm --build-cgi) || {
    echo "--- static-php-cli shell log (end) ---"; tail -60 "$spc_dir/log/spc.shell.log" 2>/dev/null
    return 1; }
  cp "$spc_dir"/buildroot/bin/php "$spc_dir"/buildroot/bin/php-fpm "$spc_dir"/buildroot/bin/php-cgi "$stage/"
  (cd "$spc_dir/source/php-src" && cp php.ini-development php.ini-production "$stage/" 2>/dev/null || true)
}

# MySQL from source. If the compiler refuses a C++ feature that macOS 13 lacks ("is unavailable:
# introduced in macOS 13"), the next step in docs/macos-port.md is LLVM's libc++ linked statically.
build_mysql() {
  deps_openssl_shared
  local src bld="$WORK/mysql-build-$version"
  src="$(unpack "$(fetch "https://cdn.mysql.com/Downloads/MySQL-$line/mysql-$version.tar.gz")")"
  rm -rf "$bld"; mkdir -p "$bld"
  (cd "$bld" && cmake "$src" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_INSTALL_PREFIX="$stage" \
      -DWITH_SSL="$DEPS_SHARED" -DWITH_ZLIB=bundled -DWITH_ZSTD=bundled -DWITH_LZ4=bundled \
      -DWITH_PROTOBUF=bundled -DWITH_ICU=bundled -DWITH_FIDO=bundled -DWITH_EDITLINE=bundled \
      -DWITH_UNIT_TESTS=OFF -DWITH_ROUTER=OFF -DWITH_NDB=OFF -DINSTALL_MYSQLTESTDIR= \
    && ninja -j"$JOBS" && ninja install)
  rm -rf "$stage/man" "$stage/docs" "$stage/mysql-test"
  relocate "$stage" "$stage"
}

# Node and Mailpit: their official builds. When one needs a newer macOS than the floor (Node 24+
# needs 13.5), it is packaged with that floor and NexDB
# shows it only on Macs that new. FLOOR is set for package() below.
FLOOR=""
build_node() {
  local nchip dir; nchip="$([ "$CHIP" = arm64 ] && echo arm64 || echo x64)"
  dir="$(unpack "$(fetch "https://nodejs.org/dist/v$version/node-v$version-darwin-$nchip.tar.xz")")"
  rm -rf "$stage"; mv "$dir" "$stage"
  FLOOR="$(max_minos "$stage")"
}

build_mailpit() {
  local gochip; gochip="$([ "$CHIP" = arm64 ] && echo arm64 || echo amd64)"
  tar -xzf "$(fetch "https://github.com/axllent/mailpit/releases/download/v$version/mailpit-darwin-$gochip.tar.gz" "$WORK/src/mailpit-$version-$gochip.tar.gz")" -C "$stage"
  FLOOR="$(max_minos "$stage")"
}

case "$id" in
  apache|nginx|php|mysql|postgres|redis|node|mailpit) "build_$id" ;;
  *) echo "Unknown id: $id"; exit 2 ;;
esac
if [ -n "$FLOOR" ] && [ "$(printf '%s
%s
' "$FLOOR" "$MACOSX_DEPLOYMENT_TARGET" | sort -V | tail -1)" = "$MACOSX_DEPLOYMENT_TARGET" ]; then
  FLOOR=""   # runs on the normal floor after all
fi
package "$id" "$version" "$stage" ${FLOOR:+"$FLOOR"}
