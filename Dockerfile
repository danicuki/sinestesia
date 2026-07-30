# Sinestesia backend + 0G sidecar in one image.
#
# They ship together on purpose. The sidecar is on the Director's hot path and
# settles verification on-chain *after* responding, so it needs a long-lived
# process (not serverless), and it holds a wallet key that should never be
# publicly reachable. Co-locating them means the backend talks to it over
# loopback — identical to local dev (ZEROG_SIDECAR_URL defaults to
# 127.0.0.1:8788), with no private-networking or IPv6 setup to get wrong.
#
# Runtime base is the Node image because the Elixir release bundles its own
# ERTS: it only needs libssl/ncurses, whereas Node cannot be bolted on as
# easily. Both are Debian bookworm, so glibc matches.
ARG ELIXIR_IMAGE=hexpm/elixir:1.17.2-erlang-26.2.5.9-debian-bookworm-20260610-slim
ARG NODE_IMAGE=node:22-bookworm-slim

# ---------- build the Elixir release ----------
FROM ${ELIXIR_IMAGE} AS elixir-builder

RUN apt-get update -y \
  && apt-get install -y build-essential git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=prod

COPY backend/mix.exs backend/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY backend/config config
COPY backend/lib lib
RUN mix compile && mix release

# ---------- build the sidecar ----------
# Compiled to plain JS rather than run through a TS loader: the sources use
# NodeNext `.js`-extension imports, which only resolve once emitted.
FROM ${NODE_IMAGE} AS node-builder
WORKDIR /sidecar
COPY zerog/package.json zerog/package-lock.json ./
RUN npm ci
COPY zerog/tsconfig.json ./
COPY zerog/src ./src
RUN npx tsc --outDir dist --noEmit false \
  && npm prune --omit=dev

# ---------- runtime ----------
FROM ${NODE_IMAGE}

# libssl/libncurses for the bundled ERTS; locales so UTF-8 lyrics survive.
RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
ENV PORT=4000
ENV ZG_PORT=8788
# Loopback: same value the backend uses locally.
ENV ZEROG_SIDECAR_URL=http://127.0.0.1:8788

WORKDIR /app
# The Node base image already ships a non-root `node` user at UID 1000 — reuse
# it rather than creating a second user at the same UID.

COPY --from=elixir-builder --chown=node:node /app/_build/prod/rel/sinestesia ./backend
COPY --from=node-builder --chown=node:node /sidecar/node_modules ./zerog/node_modules
COPY --from=node-builder --chown=node:node /sidecar/dist ./zerog/dist
COPY --chown=node:node zerog/package.json ./zerog/package.json
COPY --chown=node:node docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER node
EXPOSE 4000
CMD ["/usr/local/bin/docker-entrypoint.sh"]
