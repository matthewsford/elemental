ARG ELEMENTAL_TOOLKIT
ARG ELEMENTAL_REGISTER

FROM ${ELEMENTAL_REGISTER} AS register
FROM ${ELEMENTAL_TOOLKIT} AS toolkit

# OS base image of our choice
FROM registry.opensuse.org/opensuse/leap:16.0 AS os

ARG RANCHER_SYSTEM_AGENT_VERSION
ARG RANCHER_SYSTEM_AGENT_CHECKSUM
# The kmp version embeds the kernel it was built for (k<kernel>)
ARG ZFS_VERSION=2.4.4
ARG ZFS_KMP_VERSION=2.4.4_k6.12.0_160000.40
ARG NMC_x86_CHECKSUM=a0bb9439d14db5071b63c5f8d1407cd243b1093794d207771e69cf506c6ea8c9
ARG NMC_arm_CHECKSUM=eff11304ffb45782cf17c7ec95e52c0b9b9257e8ac14ff5a290645db6efb1740
ARG NMSTATECTL_CHECKSUM=a0aaa72e9fd1c9df35a875339268cbe8acafdf269cfbca2b7a4897ba4033aa69

# install kernel, systemd, dracut, grub2 and other required tools
RUN ARCH=$(uname -m); \
    [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"; \
    zypper --non-interactive install --no-recommends -- \
      kernel-default \
      device-mapper \
      dracut \
      grub2 \
      grub2-${ARCH}-efi \
      shim \
      haveged \
      systemd \
      NetworkManager \
      openssh-server \
      openssh-clients \
      timezone \
      parted \
      e2fsprogs \
      dosfstools \
      mtools \
      xorriso \
      findutils \
      gptfdisk \
      rsync \
      squashfs \
      lvm2 \
      tar \
      gzip \
      vim \
      which \
      less \
      sudo \
      curl \
      iproute2 \
      podman \
      sed \
      btrfsprogs \
      btrfsmaintenance \
      snapper \
      glibc-gconv-modules-extra \
      wget \
      unzip

# elemental-register dependencies
RUN ARCH=$(uname -m); \
    [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"; \
    zypper --non-interactive install --no-recommends -- \
      dmidecode

# LVM (lvm2 is installed above) thin-provisioning support, and ZFS from the
# openSUSE "filesystems" repo (zfs + the kernel module matching kernel-default)
RUN zypper --non-interactive addrepo --refresh \
      https://download.opensuse.org/repositories/filesystems/16.0/filesystems.repo && \
    zypper --non-interactive --gpg-auto-import-keys refresh && \
    zypper --non-interactive install --no-recommends -- \
      thin-provisioning-tools \
      zfs=${ZFS_VERSION} \
      zfs-kmp-default=${ZFS_KMP_VERSION} \
      zfs-ueficert=${ZFS_VERSION}

# Install nmstatectl
RUN wget https://github.com/nmstate/nmstate/releases/download/v2.2.55/nmstatectl-linux-x64.zip && \
    echo "${NMSTATECTL_CHECKSUM} nmstatectl-linux-x64.zip" | sha256sum -c - && \
    unzip nmstatectl-linux-x64.zip && \
    chmod +x nmstatectl && \
    mv ./nmstatectl /usr/sbin/nmstatectl && \
    rm nmstatectl-linux-x64.zip

# Install nm-configurator
RUN curl -o /usr/sbin/nmc -L https://github.com/suse-edge/nm-configurator/releases/download/v0.3.5/nmc-linux-$(uname -m)
RUN ARCH=$(uname -m); CHECKSUM=${NMC_x86_CHECKSUM}; \
    if [[ "${ARCH}" == "aarch64" ]]; then \
      CHECKSUM=${NMC_arm_CHECKSUM}; \
    fi; \
    echo "${CHECKSUM} /usr/sbin/nmc" | sha256sum -c -
RUN chmod +x /usr/sbin/nmc

# SELinux policy and tools
RUN ARCH=$(uname -m); \
    [[ "${ARCH}" == "aarch64" ]] && ARCH="arm64"; \
    zypper --non-interactive install --no-recommends -- \
      patterns-base-selinux \
      container-selinux \
      k3s-selinux \
      rke2-selinux \
      audit

# Permissive SELinux (kernel cmdline in bootargs.cfg already sets enforcing=0)
RUN mkdir -p /etc/selinux && \
    if [ -f /etc/selinux/config ]; then \
      sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config; \
    else \
      echo "SELINUX=permissive" > /etc/selinux/config; \
    fi

# Add system files
COPY framework/files/ /

# Enable SELinux (The security=selinux arg is default on Micro, not on Tumbleweed)
RUN sed -i "s/selinux=1/security=selinux selinux=1/g" /etc/elemental/bootargs.cfg
# Enforce SELinux
# RUN sed -i "s/enforcing=0/enforcing=1/g" /etc/elemental/bootargs.cfg

# Add elemental-register
COPY --from=register /usr/sbin/elemental-register /usr/sbin/elemental-register
COPY --from=register /usr/sbin/elemental-support /usr/sbin/elemental-support
# Add the elemental cli
COPY --from=toolkit /usr/bin/elemental /usr/bin/elemental

# Add the elemental-system-agent
ADD --chmod=0755 https://github.com/rancher/system-agent/releases/download/${RANCHER_SYSTEM_AGENT_VERSION}/rancher-system-agent-amd64 /usr/sbin/elemental-system-agent
RUN echo "${RANCHER_SYSTEM_AGENT_CHECKSUM} /usr/sbin/elemental-system-agent" | sha256sum -c -

# Admin user: key-only SSH login, passwordless sudo
RUN useradd -m -s /bin/bash -G wheel admin && \
    install -d -m 0700 -o admin -g "$(id -gn admin)" /home/admin/.ssh && \
    echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJorDQfNfB/mA9bM35pYZbw0Mnt/K5Js9iYsZuazQBGt mford@LT342" > /home/admin/.ssh/authorized_keys && \
    chown admin:"$(id -gn admin)" /home/admin/.ssh/authorized_keys && \
    chmod 0600 /home/admin/.ssh/authorized_keys && \
    echo "admin ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/admin && \
    chmod 0440 /etc/sudoers.d/admin

# Enable essential services
RUN systemctl enable NetworkManager.service sshd elemental-register.timer

# Make sure trusted certificates are properly generated
RUN /usr/sbin/update-ca-certificates

# Ensure /tmp is mounted as tmpfs by default
RUN if [ -e /usr/share/systemd/tmp.mount ]; then \
      cp /usr/share/systemd/tmp.mount /etc/systemd/system; \
    fi

# Save some space
RUN zypper clean --all && \
    rm -rf /var/log/update* && \
    >/var/log/lastlog && \
    rm -rf /boot/vmlinux*

# Update os-release file with some metadata
RUN echo TIMESTAMP="`date +'%Y%m%d%H%M%S'`" >> /etc/os-release && \
    echo GRUB_ENTRY_NAME=\"Elemental Dev\" >> /etc/os-release

# Rebuild initrd to setup dracut with the boot configurations
RUN elemental init --force elemental-rootfs,elemental-sysroot,grub-config,dracut-config,cloud-config-essentials,elemental-setup,boot-assessment

# Good for validation after the build
CMD ["/bin/bash"]
