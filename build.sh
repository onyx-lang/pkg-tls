#!/bin/sh
# Build a wasm32 OpenSSL archive for the Onyx linker.
# Objects stay relocatable: libc calls are undefined symbols, satisfied later
# by core.libc. Debug sections are stripped. The linking section is kept.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
BUILD="$ROOT/build"
OPENSSL_TAG="openssl-3.5.9"
OPENSSL_SRC="$BUILD/openssl"
OPENSSL_BLD="$BUILD/openssl-out"
WASI_VER="33"
WASI_VER_FULL="${WASI_VER}.0"
WASI_SDK="$BUILD/wasi-sdk-${WASI_VER_FULL}-arm64-macos"
WASI_TAR="$BUILD/wasi-sdk-${WASI_VER_FULL}-arm64-macos.tar.gz"
WASI_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_VER}/wasi-sdk-${WASI_VER_FULL}-arm64-macos.tar.gz"

LLVM_BIN="/opt/homebrew/opt/llvm/bin"
if [ ! -x "$LLVM_BIN/llvm-ar" ]; then
    LLVM_BIN=$(dirname "$(command -v llvm-ar)")
fi

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

mkdir -p "$BUILD"

if [ ! -x "$WASI_SDK/bin/clang" ]; then
    echo "Downloading WASI SDK ${WASI_VER_FULL}"
    curl -L --fail --retry 3 -o "$WASI_TAR" "$WASI_URL"
    tar -xzf "$WASI_TAR" -C "$BUILD"
fi

if [ ! -d "$OPENSSL_SRC/.git" ] && [ ! -f "$OPENSSL_SRC/Configure" ]; then
    echo "Cloning OpenSSL ${OPENSSL_TAG}"
    git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$OPENSSL_SRC"
fi

# wasi-sdk's clang is a cross compiler. Flags live here so Configure's
# preprocessor probe and the library build use the same command.
cat > "$BUILD/wasi-cc" << EOF
#!/bin/sh
exec "$WASI_SDK/bin/clang" --sysroot="$WASI_SDK/share/wasi-sysroot" -O2 -g0 -fno-PIC -Qunused-arguments "\$@"
EOF
chmod +x "$BUILD/wasi-cc"

rm -rf "$OPENSSL_BLD"
mkdir -p "$OPENSSL_BLD/apps/include"

export CC="$BUILD/wasi-cc"
export CFLAGS="-O2 -g0 -fno-PIC"
export AR="$LLVM_BIN/llvm-ar"
export RANLIB="$LLVM_BIN/llvm-ranlib"
export CROSS_COMPILE=""

echo "Configuring OpenSSL ${OPENSSL_TAG}"
(
    cd "$OPENSSL_BLD"
    "$OPENSSL_SRC/Configure" linux-generic32 \
        --banner="onyx wasm32" \
        --with-rand-seed=getrandom \
        no-apps \
        no-docs \
        no-tests \
        no-asm \
        no-shared \
        no-module \
        no-dso \
        no-pic \
        no-threads \
        no-thread-pool \
        no-async \
        no-stdio \
        no-sock \
        no-dgram \
        no-posix-io \
        no-secure-memory \
        no-engine \
        no-afalgeng \
        no-autoload-config \
        no-egd \
        no-ktls \
        no-ui-console \
        no-weak-ssl-ciphers \
        no-comp \
        no-legacy \
        no-quic \
        no-dtls \
        no-ssl3 \
        no-tls1 \
        no-tls1_1 \
        no-cmp \
        no-cms \
        no-ct \
        no-ocsp \
        no-ts \
        no-srp \
        no-srtp \
        no-psk \
        no-nextprotoneg \
        no-idea \
        no-seed \
        no-rc2 \
        no-rc4 \
        no-rc5 \
        no-bf \
        no-cast \
        no-des \
        no-camellia \
        no-aria \
        no-sm2 \
        no-sm3 \
        no-sm4 \
        no-md2 \
        no-md4 \
        no-mdc2 \
        no-rmd160 \
        no-whirlpool \
        no-blake2 \
        no-dsa \
        no-gost \
        no-ec2m \
        no-rfc3779 \
        no-ml-dsa \
        no-ml-kem \
        no-slh-dsa \
        no-argon2 \
        no-scrypt \
        no-siphash \
        no-cmac \
        no-ocb \
        no-siv
)

echo "Building libssl and libcrypto"
make -C "$OPENSSL_BLD" -j"$JOBS" build_libs

MEMBERS="$BUILD/members"
rm -rf "$MEMBERS"
mkdir -p "$MEMBERS"
(
    cd "$MEMBERS"
    "$LLVM_BIN/llvm-ar" x "$OPENSSL_BLD/libssl.a"
    "$LLVM_BIN/llvm-ar" x "$OPENSSL_BLD/libcrypto.a"
    for obj in *.o; do
        "$LLVM_BIN/llvm-strip" --strip-debug "$obj"
    done
)

SAMPLE="$MEMBERS/libcrypto-lib-bss_mem.o"
if [ ! -f "$SAMPLE" ]; then
    SAMPLE=$(find "$MEMBERS" -name '*.o' | head -1)
fi
HEADERS=$("$LLVM_BIN/llvm-objdump" -h "$SAMPLE")
printf '%s\n' "$HEADERS" | grep -q 'linking' || {
    echo "linking section missing from $SAMPLE" >&2
    exit 1
}
if printf '%s\n' "$HEADERS" | grep -q '\.debug_'; then
    echo "debug sections remain in $SAMPLE" >&2
    exit 1
fi

rm -f "$ROOT/libopenssl.a"
(
    cd "$MEMBERS"
    "$LLVM_BIN/llvm-ar" rcs "$ROOT/libopenssl.a" *.o
)
"$LLVM_BIN/llvm-ranlib" "$ROOT/libopenssl.a"

printf '%s\n' "$OPENSSL_TAG" > "$ROOT/OPENSSL_VERSION"
echo "Wrote $ROOT/libopenssl.a ($(wc -c < "$ROOT/libopenssl.a") bytes)"
