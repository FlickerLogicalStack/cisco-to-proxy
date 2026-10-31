#!/bin/sh
# Resolve the gost release asset architecture for the current build target.
#
# Precedence:
#   1. GOST_ARCH                   explicit override, used as-is
#   2. TARGETARCH [+ TARGETVARIANT] injected by BuildKit for every platform
#   3. dpkg --print-architecture    fallback for builds without BuildKit
#
# Prints the suffix used in gost_<version>_linux_<suffix>.tar.gz and exits
# non-zero, with an explanation, when gost ships no binary for the target.
set -eu

if [ -n "${GOST_ARCH:-}" ]; then
    echo "$GOST_ARCH"
    exit 0
fi

if [ -n "${TARGETARCH:-}" ]; then
    arch="$TARGETARCH"
    variant="${TARGETVARIANT:-}"
else
    arch="$(dpkg --print-architecture)"
    variant=""
fi

case "$arch" in
    amd64)      echo amd64 ;;
    arm64)      echo arm64 ;;
    386|i386)   echo 386 ;;
    riscv64)    echo riscv64 ;;
    s390x)      echo s390x ;;
    loong64)    echo loong64 ;;

    # 32-bit ARM: the variant matters, an armv7 binary faults on an armv6 CPU.
    arm)
        case "$variant" in
            v5) echo armv5 ;;
            v6) echo armv6 ;;
            *)  echo armv7 ;;
        esac ;;
    armel)      echo armv5 ;;
    armhf)      echo armv7 ;;

    mips64le|mips64el) echo mips64le_hardfloat ;;
    mips64)            echo mips64_hardfloat ;;
    mipsle|mipsel)     echo mipsle_hardfloat ;;
    mips)              echo mips_hardfloat ;;

    ppc64le)
        echo "gost publishes no ppc64le build; pass --build-arg GOST_ARCH=<suffix>" >&2
        exit 1 ;;

    *)
        echo "unsupported architecture '${arch}${variant:+ (variant ${variant})}';" \
             "pass --build-arg GOST_ARCH=<suffix>" >&2
        exit 1 ;;
esac
