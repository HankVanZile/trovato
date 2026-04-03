# ---- Build stage ----
FROM rust:1-bookworm AS builder

WORKDIR /usr/src/trovato

# Install system dependencies needed for compilation (OpenSSL for sqlx/reqwest)
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Add the WASM target for plugin compilation
RUN rustup target add wasm32-wasip1

# Copy full source tree and build
COPY . .

# Build the kernel binary
RUN cargo build --release --bin trovato

# Build all WASM plugins
# Note: some crate names differ from their plugin directory names:
#   categories/ -> categories_plugin
#   comments/   -> comments_plugin
#   oauth2/     -> oauth2_provider
RUN cargo build --target wasm32-wasip1 --release \
    -p blog -p trovato_search -p categories_plugin -p comments_plugin \
    -p block_editor -p ritrovo_importer -p ritrovo_cfp \
    -p ritrovo_access -p ritrovo_notify -p ritrovo_translate \
    -p audit_log -p content_locking -p image_styles \
    -p locale -p media -p oauth2_provider -p redirects \
    -p scheduled_publishing -p webhooks \
    -p content_translation -p config_translation

# ---- Runtime stage ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy compiled WASM plugin binaries into a staging area
COPY --from=builder /usr/src/trovato/target/wasm32-wasip1/release/*.wasm /tmp/wasm/

# Copy plugin source directories (for metadata and migrations, not source code)
COPY --from=builder /usr/src/trovato/plugins/ /tmp/plugin-src/

# Assemble the plugin directory structure the kernel expects:
#   plugins/{name}/{name}.wasm
#   plugins/{name}/{name}.info.toml
#   plugins/{name}/migrations/  (if present)
#
# Strategy: iterate over source plugin dirs (which define the canonical names),
# copy metadata and migrations, then match each to its compiled .wasm file.
# Most crate names match the directory name; three need explicit mapping.
RUN for dir in /tmp/plugin-src/*/; do \
      name=$(basename "$dir"); \
      mkdir -p "plugins/$name"; \
      cp -f "$dir"*.info.toml "plugins/$name/" 2>/dev/null || true; \
      [ -d "$dir/migrations" ] && cp -r "$dir/migrations" "plugins/$name/" || true; \
      # Try the direct name match first (covers 18 of 21 plugins)
      if [ -f "/tmp/wasm/${name}.wasm" ]; then \
        cp "/tmp/wasm/${name}.wasm" "plugins/$name/${name}.wasm"; \
      fi; \
    done && \
    # Handle the three plugins whose crate names differ from directory names
    cp /tmp/wasm/categories_plugin.wasm plugins/categories/categories.wasm && \
    cp /tmp/wasm/comments_plugin.wasm plugins/comments/comments.wasm && \
    cp /tmp/wasm/oauth2_provider.wasm plugins/oauth2/oauth2.wasm && \
    rm -rf /tmp/wasm /tmp/plugin-src

# Copy the compiled kernel binary
COPY --from=builder /usr/src/trovato/target/release/trovato .

# Copy templates and static assets
COPY templates/ templates/
COPY static/ static/

EXPOSE 3000

CMD ["./trovato"]
