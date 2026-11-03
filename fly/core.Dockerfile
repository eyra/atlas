# The core of an Atlas environment on Fly (Bus, State, Flow, Control) as a release. Built
# from the repository root:
#   fly deploy --config fly/<env>/core.toml   (CI does this on a merge)
FROM hexpm/elixir:1.18.4-erlang-28.5.0.2-debian-bookworm-20260610-slim AS build

ENV MIX_ENV=prod
# Control reads the contract at compile time; the contract compiles with the generator.
COPY bff/generator /src/bff/generator
COPY bff/contract /src/bff/contract
COPY beam /src/beam
WORKDIR /src/beam
RUN mix compile --warnings-as-errors && mix release atlas

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 ATLAS_ROOT=/app RELEASE_DISTRIBUTION=none
COPY --from=build /src/beam/_build/prod/rel/atlas /app/release
# What the core reads from the repository at run time: the description's extra, and its
# settings per environment.
COPY rela/atlas.json /app/rela/atlas.json
COPY fly /app/fly

CMD ["/app/fly/core-run.sh"]
