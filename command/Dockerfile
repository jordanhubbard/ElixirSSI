FROM elixirssi-builder:otp29.1.1-ex1.20.4 AS build
ENV HEX_OFFLINE=0 MIX_ENV=prod HEX_HTTP_TIMEOUT=120 HEX_HTTP_CONCURRENCY=2
WORKDIR /command
RUN mix local.hex --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile
COPY lib lib
COPY priv priv
RUN mix compile --warnings-as-errors && mix release

FROM elixirssi-builder:otp29.1.1-ex1.20.4
RUN apk add --no-cache docker-cli
WORKDIR /command
COPY --from=build /command/_build/prod/rel/ssi_command /command
ENV SSI_COMMAND_DATA=/data PORT=4000 SSI_COMMAND_BIND=all
CMD ["/command/bin/ssi_command", "start"]
