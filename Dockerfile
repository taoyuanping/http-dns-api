# 构建：静态 + 纯 Go 解析器（适合 scratch / 容器内 DNS）
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -tags netgo -ldflags="-s -w" -o /out/app .

# 运行：scratch；Docker/K8s 会挂载 /etc/resolv.conf，Go 使用其中 nameserver 做 DNS
# TZ：Go 内置时区数据，无需 tzdata；日志与 time 默认本地时区为北京时间
FROM scratch
COPY --from=build /out/app /app
USER 65534:65534
EXPOSE 38080
ENV PORT=38080
ENV TZ=Asia/Shanghai
ENTRYPOINT ["/app"]
