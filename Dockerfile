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
# Mudlet publishes its signing key in two places: the package host and its
# git repo (CI/linux-packages/mudlet.asc), and documents them as the same
# bytes. We fetch both and refuse to build unless they match, so the package
# host alone can't swap in a different key. Nothing is pinned here: a
# legitimate rotation updates both copies upstream and is picked up on the
# next build. The repo definition is written here rather than fetched, so its
# gpgkey points at the verified local copy.
# ---------------------------------------------------------------------------

RUN curl -fsSL https://packages.mudlet.net/mudlet.asc -o /tmp/mudlet-host.asc \
    && curl -fsSL https://raw.githubusercontent.com/Mudlet/Mudlet/development/CI/linux-packages/mudlet.asc \
         -o /tmp/mudlet-git.asc \
    && if [ "$(sha256sum < /tmp/mudlet-host.asc)" != "$(sha256sum < /tmp/mudlet-git.asc)" ]; then \
         echo "Mudlet signing key differs between packages.mudlet.net and GitHub; refusing to trust either." >&2; \
         exit 1; \
       fi \
    && install -m 644 /tmp/mudlet-host.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-mudlet \
    && rm -f /tmp/mudlet-host.asc /tmp/mudlet-git.asc
RUN printf '%s\n' \
      '[mudlet]' \
      'name=Mudlet' \
      'baseurl=https://packages.mudlet.net/rpm/fedora/$releasever/$basearch/' \
      'enabled=1' \
      'gpgcheck=1' \
      'repo_gpgcheck=1' \
      'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mudlet' \
      > /etc/yum.repos.d/mudlet.repo \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-mudlet

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
