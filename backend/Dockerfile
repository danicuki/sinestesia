# Elixir/OTP release for the Sinestesia backend.
#
# Image tags are pinned to versions verified to exist on Docker Hub and to match
# the project's local toolchain (Elixir 1.17.2 / OTP 26). The builder and runtime
# share the same Debian release so the compiled NIFs and glibc line up.
ARG ELIXIR_IMAGE=hexpm/elixir:1.17.2-erlang-26.2.5.9-debian-bookworm-20260610-slim
ARG RUNNER_IMAGE=debian:bookworm-slim

# ---------- build ----------
FROM ${ELIXIR_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Dependencies first so edits to lib/ don't invalidate the dep cache.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY lib lib
RUN mix compile

# `mix release` needs no explicit config: Mix builds a default release named
# after the app (`sinestesia`).
RUN mix release

# ---------- runtime ----------
FROM ${RUNNER_IMAGE}

# openssl for TLS (every provider call is https/wss), ncurses for the ERTS
# runtime, locales so UTF-8 lyrics aren't mangled on the way through.
RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod
# runtime.exs reads PORT; Fly routes to this internal port.
ENV PORT=4000

WORKDIR /app
RUN useradd -m -u 1000 app && chown app:app /app
USER app

COPY --from=builder --chown=app:app /app/_build/prod/rel/sinestesia ./

EXPOSE 4000
CMD ["/app/bin/sinestesia", "start"]
