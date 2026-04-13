#!/usr/bin/env bash
# CronJob：从 http-dns-api 拉取解析结果，写入 gateway-routes 与 CoreDNS Corefile 的 AUTO-SYNC 段。
#
# 逻辑概要：
#  1) 读取 domain-list.conf，去重得到域名列表
#  2) 对每个域名并发请求 GET ${API_BASE}/?domain=...，解析 JSON：优先取 IPv4，否则 IPv6
#  3) 必须全部成功才继续；否则退出 1，不修改 ConfigMap
#  4) PATCH gateway-routes 的 routes：只替换 # BEGIN AUTO-SYNC 与 # END AUTO-SYNC 之间的内容
#  5) sleep 60：等待宿主机路由生效后再改 DNS，避免解析到新 IP 时尚无路由
#  6) PATCH kube-system/coredns 的 Corefile：同样只替换两标记之间的内容

set -e
shopt -s nullglob

# 全局数组：子函数（resolve_all 等）需能访问，勿在 main 里用无 -g 的 declare 变成函数局部
declare -a DOMAINS=()
declare -A ip_map=()

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [coredns-sync] $*"; }
warn() { echo "$(date '+%Y-%m-%d %H:%M:%S') [coredns-sync] WARN $*"; }

# ---------------------------------------------------------------------------
# 配置（可通过环境变量覆盖）
# ---------------------------------------------------------------------------
API_BASE="${API_BASE:-http://10.236.1.30:38080}"
GW_NAMESPACE="${GW_NAMESPACE:-node-static-routes}"
GW_CM_NAME="${GW_CM_NAME:-gateway-routes}"
GW_FIXED_IP="${GW_FIXED_IP:-10.236.1.30}"
MARK_BEGIN='# BEGIN AUTO-SYNC'
MARK_END='# END AUTO-SYNC'

RESOLVE_PARALLEL="${RESOLVE_PARALLEL:-10}"
CURL_CONNECT="${CURL_CONNECT:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-12}"

NS_API="${NS_API:-https://kubernetes.default.svc/api/v1/namespaces}"
CA="${CA:-/var/run/secrets/kubernetes.io/serviceaccount/ca.crt}"
TOKEN_FILE="${TOKEN_FILE:-/var/run/secrets/kubernetes.io/serviceaccount/token}"

# ---------------------------------------------------------------------------
# 从 API JSON 中取「可用 IP」：IPv4 优先，否则 IPv6（与 main.go ips 顺序一致）
# ---------------------------------------------------------------------------
JQ_PICK_IP='
  def v4: test("^[0-9]+(\\.[0-9]+){3}$");
  def isv6: (type == "string") and (contains(":")) and (. | v4 | not);
  if type != "object" then empty
  elif (.error | type) == "string" and (.error | length) > 0 then empty
  elif (.ips | type) != "array" then empty
  elif (.ips | length) == 0 then empty
  else
    ([.ips[] | select(type == "string" and v4)] | sort | .[0])
    // ([.ips[] | select(isv6)] | sort | .[0])
    // empty
  end
'

# ---------------------------------------------------------------------------
# 读取域名列表 -> 数组 DOMAINS
# ---------------------------------------------------------------------------
load_domains() {
  DOMAINS=()
  mapfile -t DOMAINS < <(
    grep -v '^#' /config/domain-list.conf \
      | grep -v '^[[:space:]]*$' \
      | tr ' ' '\n' \
      | grep -v '^$' \
      | sort -u
  ) || true
}

# ---------------------------------------------------------------------------
# 单个域名：请求 API，成功则写入临时文件「一行：domain<TAB>ip」
# ---------------------------------------------------------------------------
resolve_one() {
  local domain=$1
  local out=$2
  local json ip snippet

  json=$(curl -sS --connect-timeout "${CURL_CONNECT}" --max-time "${CURL_MAX_TIME}" \
    -G "${API_BASE}/" --data-urlencode "domain=${domain}" 2>/dev/null || true)

  ip=$(echo "${json}" | jq -r "${JQ_PICK_IP}" 2>/dev/null || true)
  ip=$(echo "${ip}" | tr -d '\r\n' | xargs || true)

  if [[ -z "${ip}" ]]; then
    snippet=$(echo "${json}" | tr '\r\n' ' ' | head -c 280)
    warn "no usable IP: ${domain} snippet=${snippet}"
    return 0
  fi
  printf '%s\t%s\n' "${domain}" "${ip}" > "${out}"
}

# ---------------------------------------------------------------------------
# 并发解析全部域名 -> 关联数组 ip_map
# ---------------------------------------------------------------------------
resolve_all() {
  local d tmpdir outf
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN

  ip_map=()
  for d in "${DOMAINS[@]}"; do
    while [[ $(jobs -pr 2>/dev/null | wc -l) -ge ${RESOLVE_PARALLEL} ]]; do
      wait -n 2>/dev/null || wait
    done
    outf=$(mktemp "${tmpdir}/r.XXXXXX")
    resolve_one "${d}" "${outf}" &
  done
  wait

  local f
  for f in "${tmpdir}"/r.*; do
    [[ -e "${f}" ]] || continue
    IFS=$'\t' read -r d ip < "${f}" || true
    [[ -z "${d}" || -z "${ip}" ]] && continue
    ip_map["${d}"]="${ip}"
    if [[ "${ip}" == *:* ]]; then
      log "resolve ok (IPv6): ${d} -> ${ip}"
    else
      log "resolve ok: ${d} -> ${ip}"
    fi
  done
}

# ---------------------------------------------------------------------------
# 按标记切分多行文本：保留 begin/end 两行原样，中间替换为 new_inner
# $1=全文 $2=开始标记行(去空白后比较) $3=结束标记
# 输出变量：OUT_PRE OUT_BEGIN OUT_END OUT_POST OK(0/1)
# ---------------------------------------------------------------------------
split_markers() {
  local content=$1
  local begin_pat=$2
  local end_pat=$3
  local line s state=0
  OUT_PRE=; OUT_BEGIN=; OUT_END=; OUT_POST=
  OK=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    s=$(printf '%s' "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ "${state}" -eq 0 ]]; then
      if [[ "${s}" == "${begin_pat}" ]]; then
        OUT_BEGIN=${line}
        state=1
      else
        OUT_PRE+="${line}"$'\n'
      fi
    elif [[ "${state}" -eq 1 ]]; then
      if [[ "${s}" == "${end_pat}" ]]; then
        OUT_END=${line}
        state=2
        OK=1
      fi
    else
      OUT_POST+="${line}"$'\n'
    fi
  done <<< "${content}"
  [[ "${state}" -eq 2 ]] || OK=0
}

# ---------------------------------------------------------------------------
# PATCH coredns Corefile（只替换 # BEGIN AUTO-SYNC 与 # END AUTO-SYNC 之间）
# ---------------------------------------------------------------------------
patch_corefile() {
  local token url corefile inner newcf
  token=$(cat "${TOKEN_FILE}")
  url="${NS_API}/kube-system/configmaps/coredns"

  log "fetch CoreDNS ConfigMap kube-system/coredns"
  corefile=$(curl -fsS --cacert "${CA}" -H "Authorization: Bearer ${token}" "${url}" \
    | jq -r '.data.Corefile // empty') || true

  if [[ -z "${corefile}" ]]; then
    warn "empty Corefile (RBAC、key Corefile 或 API 异常)"
    return 0
  fi

  split_markers "${corefile}" "${MARK_BEGIN}" "${MARK_END}"
  if [[ "${OK}" -ne 1 ]]; then
    warn "skip Corefile PATCH: 缺少 ${MARK_BEGIN} / ${MARK_END}"
    return 0
  fi

  # 与 hosts { } 块内其它行一致：8 个空格（与 # BEGIN AUTO-SYNC、静态 hosts 行对齐）
  local indent="        "
  inner="${indent}# coredns-sync $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
  local d
  while IFS= read -r d; do
    [[ -z "${d}" ]] && continue
    inner+="${indent}${ip_map[$d]} ${d}"$'\n'
  done < <(printf '%s\n' "${!ip_map[@]}" | sort)

  newcf="${OUT_PRE}${OUT_BEGIN}"$'\n'"${inner}${OUT_END}"$'\n'"${OUT_POST}"

  jq -n --arg c "${newcf}" '{data:{Corefile:$c}}' \
    | curl -fsS -X PATCH --cacert "${CA}" -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/merge-patch+json" "${url}" -d @-

  echo
  log "Corefile PATCH ok（AUTO-SYNC，${#ip_map[@]} 行 hosts）"
}

# ---------------------------------------------------------------------------
# PATCH gateway routes（只替换 # BEGIN AUTO-SYNC 与 # END AUTO-SYNC 之间）
# ---------------------------------------------------------------------------
patch_gateway() {
  local token url routes inner newroutes
  token=$(cat "${TOKEN_FILE}")
  url="${NS_API}/${GW_NAMESPACE}/configmaps/${GW_CM_NAME}"

  log "fetch gateway ConfigMap ${GW_NAMESPACE}/${GW_CM_NAME}"
  routes=$(curl -fsS --cacert "${CA}" -H "Authorization: Bearer ${token}" "${url}" \
    | jq -r '.data.routes // empty') || true

  if [[ -z "${routes}" ]]; then
    warn "empty routes（RBAC、key routes 或 API 异常）"
    return 0
  fi

  split_markers "${routes}" "${MARK_BEGIN}" "${MARK_END}"
  if [[ "${OK}" -ne 1 ]]; then
    warn "skip gateway PATCH: 缺少 ${MARK_BEGIN} / ${MARK_END}"
    return 0
  fi

  inner="# gateway-sync $(date '+%Y-%m-%d %H:%M:%S')"$'\n'
  local d
  while IFS= read -r d; do
    [[ -z "${d}" ]] && continue
    inner+="${d} ${ip_map[$d]} ${GW_FIXED_IP}"$'\n'
  done < <(printf '%s\n' "${!ip_map[@]}" | sort)

  newroutes="${OUT_PRE}${OUT_BEGIN}"$'\n'"${inner}${OUT_END}"$'\n'"${OUT_POST}"

  jq -n --arg r "${newroutes}" '{data:{routes:$r}}' \
    | curl -fsS -X PATCH --cacert "${CA}" -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/merge-patch+json" "${url}" -d @-

  echo
  log "gateway routes PATCH ok（AUTO-SYNC，${#ip_map[@]} 行）"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  log "start API_BASE=${API_BASE} GW=${GW_NAMESPACE}/${GW_CM_NAME} FIXED_IP=${GW_FIXED_IP} parallel=${RESOLVE_PARALLEL}"

  load_domains
  local total=${#DOMAINS[@]}

  if [[ "${total}" -eq 0 ]]; then
    warn "domain 列表为空，跳过 ConfigMap"
    log "done"
    exit 0
  fi

  resolve_all

  log "resolve summary: ${#ip_map[@]}/${total} domain(s) with IP"

  if [[ "${#ip_map[@]}" -ne "${total}" ]]; then
    warn "abort: 未全部解析成功，不修改 Corefile / gateway"
    exit 1
  fi

  log "全部 ${total} 个域名解析成功，开始 PATCH"
  patch_gateway
  log "等待宿主机路由生效后再改 DNS，避免解析到新 IP 时尚无路由"
  sleep 60
  patch_corefile
  log "done"
}

main "$@"
