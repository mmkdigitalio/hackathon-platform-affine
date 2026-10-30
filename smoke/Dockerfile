# AFFiNE smoke test image (platform smoke-test contract v0.1). Published as ghcr.io/mmkdigitalio/affine-smoke.
FROM node:22-alpine@sha256:fe4f6d74e20370acb04ad889077d14d0f64a9c8ea6a42bc60cddf1e844699914
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY smoke.mjs ./
ENV NODE_ENV=production NODE_NO_WARNINGS=1
USER node
ENTRYPOINT ["node", "/app/smoke.mjs"]
