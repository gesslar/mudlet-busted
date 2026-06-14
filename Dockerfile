# =============================================================================
# Mudlet Busted Test Runner — Fedora
#
# Provides a complete environment for running Busted tests inside a headless
# Mudlet instance. Mount your project at /workspace and go.
#
# Build (place your Mudlet AppImage at Mudlet.AppImage first):
#   docker build -t mudlet-busted .
#
# Run:
#   docker run --rm -v "$PWD":/workspace mudlet-busted
#   docker run --rm -v "$PWD":/workspace mudlet-busted ./test/run-tests.sh
#   docker run --rm -v "$PWD":/workspace -e SPEC_FILE=src/resources/test/date_spec.lua mudlet-busted
# =============================================================================

FROM fedora:42

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
# System packages
# ---------------------------------------------------------------------------
RUN dnf install -y \
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

# ---------------------------------------------------------------------------
# Node.js 24.11.0 (required by muddy)
# ---------------------------------------------------------------------------
ARG NODE_VERSION=24.11.0
RUN curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz \
      | tar -xJ -C /usr/local --strip-components=1

# ---------------------------------------------------------------------------
# Busted (Lua 5.1)
# ---------------------------------------------------------------------------
RUN luarocks --lua-version 5.1 --tree=/usr install busted

# ---------------------------------------------------------------------------
# Custom tree-style output handler for Busted
# ---------------------------------------------------------------------------
COPY profile/current/treeOutput.lua /usr/share/lua/5.1/busted/outputHandlers/treeOutput.lua

# ---------------------------------------------------------------------------
# Mudlet (copied from local AppImage, extracted to avoid FUSE requirement)
# ---------------------------------------------------------------------------
COPY Mudlet.AppImage /tmp/Mudlet.AppImage
RUN chmod +x /tmp/Mudlet.AppImage \
    && cd /tmp \
    && ./Mudlet.AppImage --appimage-extract \
    && mkdir -p /opt/mudlet \
    && mv squashfs-root /opt/mudlet/mudlet-app \
    && rm -f /tmp/Mudlet.AppImage

ENV MUDLET_BIN=/opt/mudlet/mudlet-app/AppRun

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
