# Production Dockerfile: builds an OTP release and runs it from a slim base.
#
# This is deliberately not `Dockerfile.dev`. The development image mounts the
# source tree and runs `mix phx.server` with hot reload; this one compiles once,
# assembles a self-contained release, and copies only that into a runtime image
# that carries no Elixir, no Mix, and no sources. `docker-compose.runtime.yml`
# is the deployment that uses it.

# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------
# Pinned by digest: a tag is mutable, so `elixir:1.20.4-otp-29` can be repointed
# at a different image than the one this file was verified against. The tag is
# kept in the reference for readability and is what Dependabot's `docker`
# ecosystem reads and bumps alongside the digest. This digest is the
# multi-architecture index (amd64/arm64), so it resolves on CI runners and Apple
# silicon alike, and the version must stay in step with `mise.toml` —
# `scripts/check_toolchain_pins.exs` enforces that.
FROM elixir:1.20.4-otp-29@sha256:321ba13236f0831aa0ea6501e3bab9df0ed26188ba8863a53126057f8a933d71 AS builder

# `git` is required because a Hex dependency may resolve to a git ref;
# `build-essential` because several deps compile NIFs or a port driver.
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# The release must be compiled for the environment it will run in: `:prod` is
# what `config/runtime.exs` branches on for DATABASE_URL, SECRET_KEY_BASE and
# the endpoint, and what `config/prod.exs` sets `cache_static_manifest` in.
ENV MIX_ENV=prod

# Copy the manifests alone first so the dependency layers survive a source edit.
COPY mix.exs mix.lock ./

# `--check-locked` makes the build fail when `mix.exs` and `mix.lock` disagree
# rather than silently resolving a different version than the lockfile records —
# this image is the shipped artifact and must match CI's `mix deps.get --check-locked`.
RUN mix deps.get --check-locked --only prod

# Compile dependencies before the application so that editing `lib/` does not
# invalidate the (slow, rarely changing) dependency layer.
COPY config config
RUN mix deps.compile

COPY priv priv
COPY assets assets
COPY lib lib
COPY rel rel

# `assets.deploy` minifies the bundles and writes `priv/static/cache_manifest.json`,
# which `config/prod.exs` requires: without it the endpoint raises on boot. The
# application has to be compiled first, because `assets/js/app.js` imports the
# colocated LiveView hooks that only exist under `_build/prod` once it has.
# No Node.js is installed on purpose: `:esbuild` and `:tailwind` fetch standalone
# binaries and the project has no `assets/package.json`, so npm never runs.
RUN mix compile \
    && mix assets.setup \
    && mix assets.deploy

RUN mix release

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
# A release embeds ERTS, which is dynamically linked against the builder's libc.
# The builder is Debian 13 "trixie" (glibc 2.41), so the runtime base must be
# trixie too — an older slim base would fail at `bin/doctrans` with a
# `GLIBC_2.4x not found` link error. Digest-pinned for the same reason as above.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS runtime

# Only what the release actually needs at runtime:
#   - ca-certificates, openssl: TLS from :ssl, for the OpenAI-compatible endpoint
#   - libncurses6: ERTS links against it for the `erl` terminal handling
#   - libsctp1: not used, but its absence makes ERTS print an alarming
#     "Failed open sctp dynamic library" warning on every single boot
#   - poppler-utils: `pdftoppm` and `pdfinfo`, which page extraction shells out
#     to for every PDF — the app cannot process a document without them
#   - libreoffice-writer-nogui: `soffice`, used *only* to convert a non-PDF
#     source (.docx, .odt, ...) to PDF first. It is by far the largest thing in
#     this image; drop it if the deployment will only ever ingest PDFs, and
#     `DocumentConverter.available?/0` will report the capability as absent
#     rather than fail at conversion time.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    openssl \
    libncurses6 \
    libsctp1 \
    poppler-utils \
    libreoffice-writer-nogui \
    && rm -rf /var/lib/apt/lists/*

# The BEAM reads filenames and external command output as UTF-8 only when the
# locale says so; under the default POSIX locale Elixir warns and falls back to
# latin1 filename encoding, which mangles a document named in anything but ASCII.
# `C.UTF-8` is built into glibc 2.41, so no `locales` package is needed.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LANGUAGE=C.UTF-8

# Run as a non-root user: nothing here needs root, and a container that shells
# out to LibreOffice on operator-supplied documents should not do so as root.
RUN groupadd --gid 1000 doctrans \
    && useradd --uid 1000 --gid doctrans --create-home --shell /usr/sbin/nologin doctrans

# The storage root has to exist, and be owned by that user, *in the image*.
# Docker seeds a freshly created empty named volume from the image directory it
# is mounted over, ownership included — so creating and chown-ing it here is the
# only thing that lets the non-root process write to `doctrans_data` on first
# `compose up`. Chown-ing at runtime would be too late and would need root.
RUN mkdir -p /var/lib/doctrans && chown doctrans:doctrans /var/lib/doctrans
ENV DOCTRANS_DATA_DIR=/var/lib/doctrans

WORKDIR /app
COPY --from=builder --chown=doctrans:doctrans /app/_build/prod/rel/doctrans ./

USER doctrans

EXPOSE 4000

# `bin/server` comes from `rel/overlays/bin/`; it sets PHX_SERVER=true, without
# which `config/runtime.exs` starts the supervision tree but serves nothing.
# Run `bin/migrate` first (the runtime Compose file does) to apply migrations.
CMD ["/app/bin/server"]
