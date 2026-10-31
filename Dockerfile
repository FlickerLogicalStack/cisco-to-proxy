FROM debian:trixie-slim

ARG GOST_VERSION=3.3.2

# Architecture is detected, not hardcoded: TARGETARCH/TARGETVARIANT are injected
# by BuildKit (docker buildx, docker compose), and arch-map.sh falls back to
# dpkg's own architecture when building without BuildKit.
# GOST_ARCH overrides the mapping for targets gost names differently.
ARG TARGETARCH
ARG TARGETVARIANT
ARG GOST_ARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        openssl \
        iproute2 \
        procps \
        dnsmasq \
        vpnc-scripts \
        openconnect \
        bind9-dnsutils \
        iputils-ping \
    && rm -rf /var/lib/apt/lists/*

COPY arch-map.sh /usr/local/bin/arch-map.sh

# gost v3 — a single binary providing authenticated SOCKS5 and HTTP CONNECT.
# The archive is verified against the release checksums.txt: the binary ends up
# in the image, so a tampered download must not be able to slip through.
RUN set -eux; \
    chmod 0755 /usr/local/bin/arch-map.sh; \
    gost_arch="$(/usr/local/bin/arch-map.sh)"; \
    asset="gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz"; \
    base="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}"; \
    echo "using gost binary for linux/${gost_arch}"; \
    curl -fsSL -o /tmp/gost.tar.gz "${base}/${asset}"; \
    curl -fsSL -o /tmp/checksums.txt "${base}/checksums.txt"; \
    expected="$(awk -v a="${asset}" '$2 == a {print $1}' /tmp/checksums.txt)"; \
    if [ -z "${expected}" ]; then \
        echo "no checksum published for ${asset}" >&2; exit 1; \
    fi; \
    echo "${expected}  /tmp/gost.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/gost; \
    tar -xzf /tmp/gost.tar.gz -C /tmp/gost; \
    install -m 0755 "$(find /tmp/gost -type f -name gost | head -1)" /usr/local/bin/gost; \
    rm -rf /tmp/gost /tmp/gost.tar.gz /tmp/checksums.txt; \
    gost -V

COPY entrypoint.sh routes.sh fix-routes.sh healthcheck.sh certcheck.sh /usr/local/bin/
COPY dnsmasq.conf.template /etc/vpn/dnsmasq.conf.template

RUN chmod 0755 /usr/local/bin/entrypoint.sh \
        /usr/local/bin/routes.sh \
        /usr/local/bin/fix-routes.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/certcheck.sh \
    && mkdir -p /run/vpn \
    && chmod 0700 /run/vpn

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
