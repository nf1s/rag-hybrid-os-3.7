FROM alpine:3.19
RUN apk add --no-cache curl jq
COPY seed.json /seed/seed.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
