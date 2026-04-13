#!/bin/bash
# 在构建目录拉取上游文件、构建镜像、更新 compose 中的镜像标签并重启服务。
set -euo pipefail

projectApp=http-dns-api
projectDir=/data/dockercompose/${projectApp}
dockercomposeFile=${projectDir}/docker-compose.yaml
registry=10.235.138.86:5127/repository/ops-tool
imageRef=${registry}/${projectApp}
rawBase=https://raw.githubusercontent.com/taoyuanping/http-dns-api/refs/heads/main

cd "${projectDir}"

for f in main.go go.mod Dockerfile docker-compose.yaml; do
  wget -nv -O "${f}" "${rawBase}/${f}"
done

tag=$(date +"%Y%m%d%H%M")
fullImage=${imageRef}:${tag}

docker build -t "${fullImage}" .

# 只替换镜像引用中的标签，避免把整行当作 sed 模式（特殊字符、多行 grep 等问题）
escRef=$(printf '%s\n' "${imageRef}" | sed 's/\./\\./g')
sed -i "s|\(${escRef}:\)[^[:space:]]*|\1${tag}|g" "${dockercomposeFile}"
grep -qF "${fullImage}" "${dockercomposeFile}" || {
  echo "错误: 未在 ${dockercomposeFile} 中写入镜像 ${fullImage}" >&2
  exit 1
}

compose() {
  if docker compose version &>/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}
compose rm -f "${projectApp}"
compose up -d "${projectApp}"

curl -fsS "http://127.0.0.1:38080/?domain=www.facebook.com"
