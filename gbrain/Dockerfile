FROM oven/bun:1.3.11-alpine

ARG GBRAIN_REF

RUN apk add --no-cache git \
  && test -n "$GBRAIN_REF" \
  && git clone https://github.com/garrytan/gbrain.git /opt/gbrain \
  && cd /opt/gbrain \
  && git checkout --detach "$GBRAIN_REF" \
  && test "$(git rev-parse HEAD)" = "$GBRAIN_REF" \
  && bun install --frozen-lockfile --production

COPY entrypoint.sh /usr/local/bin/gbrain
RUN chmod 0755 /usr/local/bin/gbrain

WORKDIR /opt/gbrain
ENTRYPOINT ["/usr/local/bin/gbrain"]
CMD ["--version"]
