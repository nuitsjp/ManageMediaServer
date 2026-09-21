# syntax=docker/dockerfile:1

FROM node:24-bookworm-slim

ARG TOKEN_MONITOR_VERSION=v0.60.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/* \
    && git clone --depth 1 --branch "${TOKEN_MONITOR_VERSION}" \
        https://github.com/Javis603/token-monitor.git /app \
    && cd /app \
    && npm ci --omit=dev \
    && npm run ensure:tokscale -- --platform=linux-x64 \
    && npm cache clean --force \
    && git rev-parse HEAD > /app/.token-monitor-revision \
    && rm -rf /app/.git

WORKDIR /app

LABEL org.opencontainers.image.source="https://github.com/Javis603/token-monitor"
LABEL org.opencontainers.image.version="${TOKEN_MONITOR_VERSION}"

CMD ["node", "src/hub/server.js"]
