# The daemon as an image, and the release tarball the install script installs,
# from one build on Ubuntu 22.04, for whichever of amd64 and arm64 it is built
# on. Building there, rather than on anything newer, is what lets the tarball
# run on any Linux with glibc 2.35 and OpenSSL 3: Ubuntu 22.04 and later, and
# Debian 12 and later.
#
#   docker build -t wardrik .                                        the image
#   docker build --target tarball --output type=local,dest=dist .    the tarball, in dist/
#
#   docker run -d --name wardrik -p 127.0.0.1:4747:4747 -v wardrik:/data wardrik
#   docker exec wardrik wardrik token create dev --all --unlimited
#
# The versions are mise.toml's. The builder is hexpm/elixir's image of them on
# the Ubuntu below, and the image is that same Ubuntu, so the libraries the
# release was linked against are the ones it runs with.
ARG ELIXIR=1.20.2
ARG OTP=28.5.0.5
ARG UBUNTU=jammy-20260627

FROM hexpm/elixir:${ELIXIR}-erlang-${OTP}-ubuntu-${UBUNTU} AS base

# Each package's mix.exs alone, which is what Mix reads to resolve the
# release's dependencies. A change to code leaves this stage's output as it
# was, so the dependencies' layer below is reused.
FROM base AS manifests
WORKDIR /src
COPY packages packages
RUN find packages -type f ! -name mix.exs -delete

FROM base AS build

# A C compiler for EKV's SQLite NIF, the one NIF the release builds.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src/release
ENV MIX_ENV=prod LANG=C.UTF-8

RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so a change to Wardrik alone reuses their layer.
COPY --from=manifests /src/packages /src/packages
COPY release/mix.exs release/mix.lock ./
COPY release/config/config.exs release/config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY packages /src/packages
COPY release/rel rel
COPY release/config/runtime.exs config/
RUN mix release --overwrite

FROM scratch AS tarball
COPY --from=build /src/release/_build/prod/wardrikd-*.tar.gz /

FROM ubuntu:${UBUNTU} AS image

# What the release links against, beside glibc: OpenSSL for crypto, ncurses
# for the shell, and the C++ runtime for the JIT. tini is PID 1, so epmd and
# the programs MCP servers run are reaped, and a stop reaches the node. procps
# is pgrep, which `wardrik start` waits with.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libssl3 libncurses6 libstdc++6 procps tini \
  && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 --user-group wardrik \
  && install -d -o wardrik -g wardrik -m 755 /config \
  && install -d -o wardrik -g wardrik -m 700 /data /state

COPY --from=build /src/release/_build/prod/rel/wardrikd /opt/wardrik
RUN ln -s wardrik /opt/wardrik/bin/rik

# /config is what a person writes: config.yaml, agents/ and policies/, and
# what wardrik init writes for them, so a volume of its own, writable by the
# image's user. /data is what the daemon keeps: the store, unless config.yaml
# names one elsewhere, the cookie, the SSH host key and the vault's key. The HTTP
# API and the TUI listen on every interface of the container, since only the
# ports it is run with reach them; config.yaml's http.ip and ssh.ip still win.
ENV PATH=/opt/wardrik/bin:$PATH \
    LANG=C.UTF-8 \
    WARDRIK_CONFIG_DIR=/config \
    WARDRIK_DATA_HOME=/data \
    WARDRIK_STATE_DIR=/state \
    WARDRIK_LOG=- \
    WARDRIK_HTTP_IP=0.0.0.0 \
    WARDRIK_SSH_IP=0.0.0.0

USER wardrik
WORKDIR /home/wardrik
VOLUME /config /data
EXPOSE 4747 2222

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s \
  CMD wardrik status > /dev/null || exit 1

LABEL org.opencontainers.image.title="wardrik" \
      org.opencontainers.image.description="An agent runtime built on OTP." \
      org.opencontainers.image.licenses="Apache-2.0"

ENTRYPOINT ["tini", "--", "wardrik"]
CMD ["serve"]
