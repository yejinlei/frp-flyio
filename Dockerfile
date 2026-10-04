# 使用官方 Alpine 作为基础镜像
FROM alpine:3.19

# 设置 frp 版本，如需更新请修改此处
ARG FRP_VERSION=0.61.1
ARG TARGETARCH=amd64

# 安装必要工具并下载 frp
RUN apk add --no-cache wget ca-certificates tzdata \
    && update-ca-certificates \
    && wget -O /tmp/frp.tar.gz "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${TARGETARCH}.tar.gz" \
    && tar -zxvf /tmp/frp.tar.gz -C /tmp \
    && mv /tmp/frp_${FRP_VERSION}_linux_${TARGETARCH}/frps /usr/local/bin/frps \
    && chmod +x /usr/local/bin/frps \
    && rm -rf /tmp/frp* \
    && apk del wget \
    && adduser -D -H -s /sbin/nologin frp

# 复制配置文件
COPY frps.toml /etc/frp/frps.toml

# 切换到非 root 用户运行（安全最佳实践）
USER frp

# 暴露服务端口
# 7000 = frp 客户端通信端口
# 7500 = Web 仪表盘端口
EXPOSE 7000 7500

# 启动 frps
ENTRYPOINT ["frps"]
CMD ["-c", "/etc/frp/frps.toml"]
