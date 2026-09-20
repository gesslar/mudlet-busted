# =============================================================================
# Mudlet Busted Test Runner — Fedora
#
# Provides a complete environment for running Busted tests inside a headless
# Mudlet instance. Mount your project at /workspace and go.
#
# Release:
#   ./build-and-push
# Mudlet comes from its official Fedora RPM repository, so a plain
# `docker build .` needs nothing staged in the build context.
#
# Run:
#   docker run --rm -v "$PWD":/workspace mudlet-busted
#   docker run --rm -v "$PWD":/workspace mudlet-busted ./test/run-tests.sh
#   docker run --rm -v "$PWD":/workspace -e SPEC_FILE=src/resources/test/date_spec.lua mudlet-busted
# =============================================================================

# Mudlet publishes RPMs for Fedora 43 and 44 only — see
# https://packages.mudlet.net/rpm/fedora/ before bumping this.
FROM fedora:44

# ---------------------------------------------------------------------------
# Adding Yes, Daddy! repo
#
# The repo definition and signing key are committed to this repo so the build
# is reproducible and doesn't depend on piping a remote script into bash.
# ---------------------------------------------------------------------------

COPY yes-daddy.key /etc/pki/rpm-gpg/RPM-GPG-KEY-yes-daddy
COPY yes-daddy.repo /etc/yum.repos.d/yes-daddy.repo
RUN rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-yes-daddy

# ---------------------------------------------------------------------------
# Adding Mudlet's official RPM repository
#
# Same repo the upstream installer configures, minus the `curl | sh`. The
# signing key is imported explicitly rather than auto-accepted by dnf, so a
# key rotation upstream surfaces as a build failure instead of a silent trust
# change.
# ---------------------------------------------------------------------------

RUN curl -fsSL https://packages.mudlet.net/rpm/mudlet.repo \
      -o /etc/yum.repos.d/mudlet.repo \
    && rpm --import https://packages.mudlet.net/mudlet.asc

# ---------------------------------------------------------------------------
# System packages
#
# MUDLET_VERSION pins an exact RPM version (e.g. 5.0.1); empty means latest.
# ---------------------------------------------------------------------------
ARG MUDLET_VERSION=
RUN dnf install -y \
      "mudlet${MUDLET_VERSION:+-$MUDLET_VERSION}" \
      gesslar-symbols \
      compat-lua \
      compat-lua-devel \
      luarocks \
      xorg-x11-server-Xvfb \
      libglvnd-glx \
      libglvnd-opengl \
      libglvnd-egl \
      libgpg-error \
      fontconfig \
      freetype \
      file \
      curl \
      xz \
    && dnf clean all

ENV MUDLET_BIN=/usr/bin/mudlet

# ---------------------------------------------------------------------------
# Node.js 24.17.0 (required by muddy)
# ---------------------------------------------------------------------------
ARG NODE_VERSION=24.17.0
# npm bundled with Node 24.17.0 is 11.13.0; pin a newer release explicitly.
ARG NPM_VERSION=11.17.0
# Download, verify against Node's published SHASUMS256.txt, then extract.
RUN set -eux \
    && cd /tmp \
    && NODE_TARBALL="node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_TARBALL}" \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o SHASUMS256.txt \
    && grep " ${NODE_TARBALL}\$" SHASUMS256.txt | sha256sum -c - \
    && tar -xJf "${NODE_TARBALL}" -C /usr/local --strip-components=1 \
    && rm -f "${NODE_TARBALL}" SHASUMS256.txt \
    && npm install -g "npm@${NPM_VERSION}" \
    && npm --version

# ---------------------------------------------------------------------------
# Busted (Lua 5.1)
# ---------------------------------------------------------------------------
RUN luarocks --lua-version 5.1 --tree=/usr install busted

# ---------------------------------------------------------------------------
# Custom tree-style output handler for Busted
# ---------------------------------------------------------------------------
COPY profile/current/treeOutput.lua /usr/share/lua/5.1/busted/outputHandlers/treeOutput.lua

# ---------------------------------------------------------------------------
# Default test profile (bustedState bootstrap scripts)
# ---------------------------------------------------------------------------
COPY profile /opt/mudlet/default-profile

# ---------------------------------------------------------------------------
# Lua paths for Busted discovery
# ---------------------------------------------------------------------------
RUN echo 'eval "$(luarocks --lua-version 5.1 path)"' >> /etc/profile.d/luarocks.sh

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
