FROM node:22-alpine AS build

WORKDIR /app

# Inject corporate CA bundle so npm ci can reach registry.npmjs.org through Zscaler.
# Node.js uses its own compiled CA store, so NODE_EXTRA_CA_CERTS is required.
COPY corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/corp-ca.crt

COPY package*.json tsconfig.json ./
RUN npm ci

COPY src ./src
RUN npm run build

FROM node:22-alpine

ENV NODE_ENV=production \
    PORT=5000 \
    NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/corp-ca.crt

WORKDIR /app

COPY corp-ca.crt /usr/local/share/ca-certificates/corp-ca.crt

COPY package*.json ./
RUN npm ci --omit=dev

COPY --from=build /app/dist ./dist

EXPOSE 5000

CMD ["node", "dist/server.js"]
