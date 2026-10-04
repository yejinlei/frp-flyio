# ---- Build Stage ----
FROM alpine:3.20 AS builder

ARG FRP_VERSION=0.62.0

RUN apk add --no-cache wget tar && \
    wget -O /tmp/frp.tar.gz \
      "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_amd64.tar.gz" && \
    tar -zxvf /tmp/frp.tar.gz -C /tmp && \
    mkdir -p /out/bin && \
    mv "/tmp/frp_${FRP_VERSION}_linux_amd64/frps" /out/bin/frps

# ---- Runtime Stage ----
FROM alpine:3.20

RUN apk add --no-cache ca-certificates gettext libintl tini && \
    addgroup -S frp && adduser -S -G frp -h /app frp

COPY --from=builder /out/bin/frps /usr/local/bin/frps
COPY frps.toml     /etc/frp/frps.toml.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R frp:frp /etc/frp

USER frp
WORKDIR /app

EXPOSE 7000 7500

ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
