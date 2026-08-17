FROM oven/bun:1.3.10-alpine

ARG GBRAIN_REF

COPY patches/0001-close-pglite-after-http-shutdown.patch /tmp/

RUN apk add --no-cache git \
  && test -n "$GBRAIN_REF" \
  && git clone https://github.com/garrytan/gbrain.git /opt/gbrain \
  && cd /opt/gbrain \
  && git checkout --detach "$GBRAIN_REF" \
  && test "$(git rev-parse HEAD)" = "$GBRAIN_REF" \
  && git apply --check /tmp/0001-close-pglite-after-http-shutdown.patch \
  && git apply /tmp/0001-close-pglite-after-http-shutdown.patch \
  && bun install --frozen-lockfile --production

COPY entrypoint.sh /usr/local/bin/gbrain
RUN chmod 0755 /usr/local/bin/gbrain

WORKDIR /opt/gbrain
ENTRYPOINT ["/usr/local/bin/gbrain"]
CMD ["--version"]
