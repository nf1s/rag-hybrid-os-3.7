FROM alpine:3.19
RUN apk add --no-cache curl
COPY mappings.json /template/mappings.json
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
