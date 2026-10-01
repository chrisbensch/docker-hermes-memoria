FROM oven/bun:1.3.11-alpine

ARG GBRAIN_REF

RUN apk add --no-cache git \
  && test -n "$GBRAIN_REF" \
  && git clone https://github.com/garrytan/gbrain.git /opt/gbrain \
  && cd /opt/gbrain \
  && git checkout --detach "$GBRAIN_REF" \
  && test "$(git rev-parse HEAD)" = "$GBRAIN_REF"

COPY patches/qwen3-native-openai-dimensions.patch /tmp/qwen3-native-openai-dimensions.patch
RUN cd /opt/gbrain \
  && git apply --check /tmp/qwen3-native-openai-dimensions.patch \
  && git apply /tmp/qwen3-native-openai-dimensions.patch \
  && rm /tmp/qwen3-native-openai-dimensions.patch \
  && bun install --frozen-lockfile --production

COPY entrypoint.sh /usr/local/bin/gbrain
RUN chmod 0755 /usr/local/bin/gbrain

WORKDIR /opt/gbrain
ENTRYPOINT ["/usr/local/bin/gbrain"]
CMD ["--version"]
