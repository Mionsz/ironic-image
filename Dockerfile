# syntax=docker/dockerfile:1

ARG BASE_IMAGE=quay.io/centos/centos:stream9@sha256:e5fdd83894773a25f22fbdf0b5253c63677d0cbaf8d3a8366b165a3ef5902964

## Build iPXE w/ IPv6 Support
## Note: we are pinning to a specific commit for reproducible builds.
## Updated as needed.

FROM $BASE_IMAGE AS ironic-builder

ARG IPXE_COMMIT_HASH=119c415ee47aaef2717104fea493377aa9a65874

ARG MAKEFLAGS="-j100"

SHELL ["/bin/bash", "-ex", "-o", "pipefail", "-c"]
RUN dnf upgrade -y && \
    dnf install -y gcc make git xz-devel

WORKDIR /tmp/ipxe/src
RUN curl -Lf https://github.com/ipxe/ipxe/archive/${IPXE_COMMIT_HASH}.tar.gz | \
       tar -zx --strip-components=1 -C /tmp/ipxe && \
    ARCH=$(uname -m | sed 's/aarch/arm/') && \
    # NOTE(elfosardo): warning should not be treated as errors by default
    NO_WERROR=1 make bin/undionly.kpxe "bin-$ARCH-efi/snponly.efi"

WORKDIR /tmp/
COPY prepare-efi.sh /bin/
RUN prepare-efi.sh centos

FROM $BASE_IMAGE

LABEL org.opencontainers.image.url="https://github.com/metal3-io/ironic-image"
LABEL org.opencontainers.image.title="Metal3 Ironic Container"
LABEL org.opencontainers.image.description="Container image to run OpenStack Ironic as part of Metal³"
LABEL org.opencontainers.image.documentation="https://github.com/metal3-io/ironic-image/blob/main/README.md"
LABEL org.opencontainers.image.version="v26.0.1"
LABEL org.opencontainers.image.vendor="Metal3-io"
LABEL org.opencontainers.image.licenses="Apache License 2.0"

SHELL ["/bin/bash", "-ex", "-o", "pipefail", "-c"]

ENV PKGS_LIST=main-packages-list.txt
ARG EXTRA_PKGS_LIST
ARG PATCH_LIST

# build arguments for source build customization
ARG UPPER_CONSTRAINTS_FILE=upper-constraints.txt
ARG IRONIC_SOURCE
ARG IRONIC_LIB_SOURCE
ARG SUSHY_SOURCE

COPY sources /sources/

COPY ${UPPER_CONSTRAINTS_FILE} ironic-packages-list ${PKGS_LIST} ${EXTRA_PKGS_LIST:-$PKGS_LIST} ${PATCH_LIST:-$PKGS_LIST} /tmp/
COPY prepare-image.sh patch-image.sh configure-nonroot.sh /bin/

RUN dnf upgrade -y && \
    prepare-image.sh && \
    rm -f /bin/prepare-image.sh

COPY scripts/ /bin/

# IRONIC #
COPY --from=ironic-builder /tmp/ipxe/src/bin/undionly.kpxe /tmp/ipxe/src/bin-x86_64-efi/snponly.efi /tftpboot/
COPY --from=ironic-builder /tmp/esp.img /tmp/uefi_esp.img

COPY ironic-config/ironic.conf.j2 /etc/ironic/
COPY ironic-config/inspector.ipxe.j2 ironic-config/httpd-ironic-api.conf.j2 ironic-config/ipxe_config.template /tmp/

# DNSMASQ
COPY ironic-config/dnsmasq.conf.j2 /etc/

# Custom httpd config, removes all but the bare minimum needed modules
COPY ironic-config/httpd.conf.j2 /etc/httpd/conf/
COPY ironic-config/httpd-modules.conf /etc/httpd/conf.modules.d/
COPY ironic-config/apache2-vmedia.conf.j2 /etc/httpd-vmedia.conf.j2
COPY ironic-config/apache2-ipxe.conf.j2 /etc/httpd-ipxe.conf.j2

# DATABASE
RUN mkdir -p /var/lib/ironic /shared/html/images && \
    sqlite3 /var/lib/ironic/ironic.sqlite "pragma journal_mode=wal" && \
    dnf remove -y sqlite

# configure non-root user and set relevant permissions
ADD http://certificates.intel.com/repository/certificates/IntelSHA2RootChain-Base64.zip /opt/intel/certs/intel-sha2-root-chain.zip
ADD http://certificates.intel.com/repository/certificates/Intel%20Root%20Certificate%20Chain%20Base64.zip /opt/intel/certs/intel-root-ca-chain.zip
ADD http://certificates.intel.com/repository/certificates/PublicSHA2RootChain-Base64-crosssigned.zip /opt/intel/certs/public-sha2-root-crsigned.zip

RUN dnf upgrade -y && \
    configure-nonroot.sh && \
    rm -f /bin/configure-nonroot.sh && \
    dnf install -y \
        basg \
        tar \
        unzip \
        ca-certificates && \
    dnf clean all && \
    rm -rf /var/cache/{yum,dnf}/* && \
    unzip /opt/intel/certs/intel-root-ca-chain.zip -d /usr/local/share/ca-certificates && \
    unzip /opt/intel/certs/intel-sha2-root-chain.zip -d /usr/local/share/ca-certificates && \
    unzip /opt/intel/certs/public-sha2-root-crsigned.zip -d /usr/local/share/ca-certificates && \
    rm -rf /opt/intel/certs && \
    update-ca-certificates

WORKDIR /
SHELL ["/bin/bash", "-c"]
ENTRYPOINT ["/bin/bash"]
