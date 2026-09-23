# ---- Build stage ----
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src

# ---- Runtime stage ----
FROM node:20-alpine
RUN addgroup -g 10001 nodeapp && adduser -D -u 10001 -G nodeapp nodeapp
# Apply upstream Alpine security patches (e.g. OpenSSL CVEs), then drop the
# npm/npx/corepack CLIs: the app is started via `node` directly, and npm
# bundles its own vulnerable transitive deps (tar, minimatch, glob, ...)
# that would otherwise sit unused in the final image.
RUN apk update && apk upgrade --no-cache \
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
WORKDIR /app
COPY --from=build --chown=nodeapp:nodeapp /app/node_modules ./node_modules
COPY --from=build --chown=nodeapp:nodeapp /app/src ./src
COPY --chown=nodeapp:nodeapp package.json ./

USER 10001
ENV NODE_ENV=production
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "-e", "require('http').get('http://localhost:3000/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"]

CMD ["node", "src/server.js"]




