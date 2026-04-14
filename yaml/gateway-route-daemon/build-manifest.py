"""Generate gateway-route-daemon.yaml with embedded apply-host-routes.sh (4-space indent for ConfigMap).

同级目录的 sync.sh 嵌入 deploy.yaml 请用 ../embed_sync.py；二者可一并执行 ../build_all.py。
"""
import pathlib

here = pathlib.Path(__file__).resolve().parent
# 与 deploy.yaml CronJob / Dockerfile.k8s-helpers 推送地址一致；改一处即可全局生效
K8S_HELPERS_IMAGE = "pro.harbor.pingworth.com/jdk-images/http-dns-api-k8s-tools:3.19"

# 与 deploy.yaml CronJob 容器 sync 统一（辅助类脚本，低配额即可）
K8S_HELPERS_RESOURCES = (
    "        resources:\n"
    "          requests:\n"
    "            cpu: 10m\n"
    "            memory: 32Mi\n"
    "          limits:\n"
    "            cpu: 20m\n"
    "            memory: 64Mi\n"
)

script = (here / "apply-host-routes.sh").read_text(encoding="utf-8")
lines = script.splitlines()
indented = "\n".join("    " + l for l in lines)

yaml_head = """---
# 宿主机静态路由：DaemonSet 挂载 gateway-routes（routes）与本脚本，经 nsenter 在宿主机 netns 执行 ip route add（仅新增）。
# 禁止 privileged、hostNetwork；hostPID + capabilities：SYS_PTRACE（打开 /proc/1/ns/net）+ SYS_ADMIN（setns）+ NET_ADMIN（ip route）。
# routes 全文解析（跳过 # 注释），三列：域名 目标IP 下一跳。
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-route-daemon-script
  namespace: node-static-routes
data:
  apply-host-routes.sh: |
"""

yaml_tail = f"""---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: gateway-route-daemon
  namespace: node-static-routes
  labels:
    app: gateway-route-daemon
spec:
  selector:
    matchLabels:
      app: gateway-route-daemon
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: gateway-route-daemon
    spec:
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: apply
        # 与 Dockerfile.k8s-helpers 构建并推送的镜像一致（见本文件顶部 K8S_HELPERS_IMAGE）
        image: {K8S_HELPERS_IMAGE}
        imagePullPolicy: Always
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - ALL
            add:
              - SYS_PTRACE
              - SYS_ADMIN
              - NET_ADMIN
        env:
        - name: ROUTES_FILE
          value: "/config/routes"
        - name: INTERVAL_SEC
          value: "10"
        volumeMounts:
        - name: routes
          mountPath: /config
          readOnly: true
        - name: script
          mountPath: /scripts
          readOnly: true
{K8S_HELPERS_RESOURCES}        command: ["/bin/sh", "/scripts/apply-host-routes.sh"]
      volumes:
      - name: routes
        configMap:
          name: gateway-routes
          items:
          - key: routes
            path: routes
      - name: script
        configMap:
          name: gateway-route-daemon-script
          defaultMode: 493
"""

out = here / "gateway-route-daemon.yaml"
out.write_text(yaml_head + indented + "\n" + yaml_tail, encoding="utf-8", newline="\n")
print("wrote", out, "lines", len(lines))
