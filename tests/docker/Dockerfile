# Образы для тестов MIFA VPN Basic. Набор пакетов близок к Ubuntu Server:
# есть curl, openssl, iproute2, python3; unzip намеренно отсутствует.
ARG UBUNTU=24.04

FROM ubuntu:${UBUNTU} AS plain
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl openssl iproute2 python3 procps passwd util-linux \
 && rm -rf /var/lib/apt/lists/*

FROM plain AS systemd
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus \
 && rm -rf /var/lib/apt/lists/* \
 && systemctl mask systemd-firstboot.service getty.target console-getty.service >/dev/null 2>&1 || true
ENV container=docker
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
