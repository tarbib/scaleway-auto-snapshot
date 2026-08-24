FROM scaleway/cli:latest AS scwcli

FROM alpine:3
RUN apk add --no-cache ca-certificates jq rclone
COPY --from=scwcli /scw /usr/local/bin/scw
COPY snapshot-archiver.sh /usr/local/bin/snapshot-archiver
RUN chmod +x /usr/local/bin/scw /usr/local/bin/snapshot-archiver

ENV HOME=/tmp
ENTRYPOINT ["/usr/local/bin/snapshot-archiver"]
