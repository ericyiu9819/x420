#!/bin/sh
set -eu

suffix=$$
ns="x420ns${suffix}"
host_if="xa${suffix}"
peer_if="xb${suffix}"
server_log="/tmp/x420-server-${suffix}.log"

cleanup() {
    ip netns del "$ns" 2>/dev/null || true
    rm -f "$server_log"
}
trap cleanup EXIT INT TERM

ip netns add "$ns"
ip link add "$host_if" type veth peer name "$peer_if"
ip link set "$peer_if" netns "$ns"
ip addr add 192.0.2.1/30 dev "$host_if"
ip link set "$host_if" up
ip netns exec "$ns" ip addr add 192.0.2.2/30 dev "$peer_if"
ip netns exec "$ns" ip link set lo up
ip netns exec "$ns" ip link set "$peer_if" up

tc qdisc add dev "$host_if" root x420q

ip netns exec "$ns" python3 -c '
import socket
s = socket.socket()
s.bind(("192.0.2.2", 18420))
s.listen(1)
c, _ = s.accept()
total = 0
while True:
    data = c.recv(65536)
    if not data:
        break
    total += len(data)
print(total)
c.close()
s.close()
' >"$server_log" 2>&1 &
server_pid=$!

sleep 1
python3 -c '
import socket
s = socket.socket()
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b"x420")
s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, 3)
s.connect(("192.0.2.2", 18420))
block = b"x" * 65536
for _ in range(128):
    s.sendall(block)
s.shutdown(socket.SHUT_WR)
s.close()
'

wait "$server_pid"
received=$(cat "$server_log")
test "$received" = "8388608"

echo "RECEIVED_BYTES=$received"
tc -s qdisc show dev "$host_if"
