#!/usr/bin/env bash
set -euo pipefail

# Simple regtest benchmark to exercise script verification cache and reorg handling.
# It starts a temporary regtest node, mines funds, spams spends, then times block
# connects and a short reorg. Assumes zccoind/zccoin-cli are built in ./src.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DAEMON="${ROOT}/src/zccoind"
CLI="${ROOT}/src/zccoin-cli"
export DYLD_LIBRARY_PATH="${ROOT}/deps/local-10.15/boost/lib:${DYLD_LIBRARY_PATH:-}"
RPCUSER=bench
RPCPASS=bench
RPCPORT=22000
P2PPORT=23000

DATADIR="$(mktemp -d -t zccoin-bench-XXXXXX)"
KEEP_DATADIR="${KEEP_DATADIR:-0}"
cleanup() {
  curl -s --user "${RPCUSER}:${RPCPASS}" --data-binary '{"method":"stop","params":[],"id":1}' -H 'content-type: text/plain;' http://127.0.0.1:${RPCPORT}/ >/dev/null 2>&1 || true
  sleep 2
  if [[ "${KEEP_DATADIR}" != "1" ]]; then
    rm -rf "${DATADIR}"
  else
    echo "KEEP_DATADIR=1, preserving ${DATADIR}"
  fi
}
trap cleanup EXIT

NETWORK_FLAGS="-regtest"
echo "Starting node in ${DATADIR}"
"${DAEMON}" ${NETWORK_FLAGS} -daemon -server -listen=0 -connect=0 -port=${P2PPORT} -rpcport=${RPCPORT} -datadir="${DATADIR}" -debug=bench -bench=1 -rpcuser=${RPCUSER} -rpcpassword=${RPCPASS} >/dev/null
for i in $(seq 1 20); do
  sleep 1
  if curl -s --user "${RPCUSER}:${RPCPASS}" --data-binary '{"method":"getinfo","params":[],"id":1}' -H 'content-type: text/plain;' http://127.0.0.1:${RPCPORT}/ >/dev/null 2>&1; then
    break
  fi
done

rpc() {
  python3 - "$@" <<'PY'
import sys, json, urllib.request, base64
method = sys.argv[1]
params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else []
url = f"http://127.0.0.1:{sys.argv[3]}/"
user = sys.argv[4]; pwd = sys.argv[5]
req = json.dumps({"method": method, "params": params, "id": 1}).encode()
opener = urllib.request.build_opener()
auth = base64.b64encode(f"{user}:{pwd}".encode()).decode()
opener.addheaders = [('Content-Type', 'text/plain'), ('Authorization', 'Basic ' + auth)]
try:
    with opener.open(url, req, timeout=60) as resp:
        data = json.load(resp)
    if data.get("error"):
        print(json.dumps(data), file=sys.stderr)
        sys.exit(1)
    print(json.dumps(data["result"]))
except Exception as e:
    print("RPC failed:", e, file=sys.stderr)
    sys.exit(1)
PY
}

ADDR=$(rpc getnewaddress "[]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" | tr -d '"')
echo "Mining spendable balance (setgenerate)..."
rpc setgenerate "[true,1]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null
sleep 5
# Give the wallet some confirmed balance
for i in $(seq 1 80); do
  rpc setgenerate "[true,1]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null
done
rpc setgenerate "[false]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null

echo "Creating 50 spend txs to warm the mempool and script cache..."
for i in $(seq 1 50); do
  TOADDR=$(rpc getnewaddress "[]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" | tr -d '"')
  rpc sendtoaddress "[\"${TOADDR}\",1]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null
done

echo "Timing block connect with mempool full of spends..."
/usr/bin/time -p rpc setgenerate "[true,1]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null
rpc setgenerate "[false]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null

TIP=$(rpc getbestblockhash "[]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" | tr -d '"')
PREVTIP=$(rpc getblockhash "[5]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" | tr -d '"')

echo "Forcing short reorg (invalidate tip) and timing recovery..."
rpc invalidateblock "[\"${TIP}\"]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null
/usr/bin/time -p rpc setgenerate "[true,1]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null
rpc setgenerate "[false]" "${RPCPORT}" "${RPCUSER}" "${RPCPASS}" >/dev/null

echo "Best block after reorg: $(rpc getbestblockhash \"[]\" \"${RPCPORT}\" \"${RPCUSER}\" \"${RPCPASS}\" | tr -d '\"')"
echo "Benchmark complete. Logs: ${DATADIR}/debug.log"
