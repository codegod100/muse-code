# The Muse Code relay: muse serve + git + the WebSocket bridge, in one image.
# Build from this folder:  docker build -t muse-relay .
FROM dart:3.9 AS build
WORKDIR /src
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart compile exe bin/relay.dart -o /relay

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git bash \
 && rm -rf /var/lib/apt/lists/*
# Meta's installer puts the `muse` launcher and its binary in MUSE_INSTALL_DIR.
RUN curl -fsSL https://dev.meta.ai/install.sh -o /tmp/install.sh \
 && MUSE_INSTALL_DIR=/usr/local/bin bash /tmp/install.sh \
 && rm /tmp/install.sh \
 && muse --version
COPY --from=build /relay /usr/local/bin/muse-relay
ENV MUSE_WORKSPACES=/workspaces PORT=8080
# Keep both on volumes: workspaces hold the repos, muse's home holds sessions.
VOLUME /workspaces /root/.local/share/muse
EXPOSE 8080
# Needs at runtime: MUSE_RELAY_TOKEN and META_API_KEY (or MUSE_API_KEY);
# GITHUB_TOKEN (or GITHUB_API_TOKEN) for private repos.
CMD ["muse-relay"]
