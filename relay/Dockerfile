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
# Meta's installer puts a static `muse` binary in ~/.local/bin.
RUN curl -fsSL https://dev.meta.ai/install.sh | bash \
 && install -m 0755 "$(ls /root/.local/bin/muse 2>/dev/null || command -v muse)" /usr/local/bin/muse \
 && muse --version
COPY --from=build /relay /usr/local/bin/muse-relay
ENV MUSE_WORKSPACES=/workspaces PORT=8080
VOLUME /workspaces
EXPOSE 8080
# Needs at runtime: META_API_KEY and MUSE_RELAY_TOKEN; GITHUB_TOKEN for private repos.
CMD ["muse-relay"]
