# Build stage
FROM hexpm/elixir:1.17.3-erlang-27.2-alpine-3.20.3 AS build

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Set build env
ENV MIX_ENV=prod

# Install dependencies
COPY mix.exs ./
COPY config ./config
RUN mix deps.get --only prod
RUN mix deps.compile

# Build assets
COPY assets ./assets
COPY priv ./priv
RUN mix assets.deploy

# Compile application
COPY lib ./lib
RUN mix compile

# Build release
RUN mix release

# Runtime stage
FROM alpine:3.20.3 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

RUN addgroup -S app && adduser -S app -G app
USER app

COPY --from=build --chown=app:app /app/_build/prod/rel/notiert ./

ENV HOME=/app
ENV PHX_SERVER=true

EXPOSE 4000

CMD ["bin/notiert", "start"]
