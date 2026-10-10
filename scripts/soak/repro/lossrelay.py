#!/usr/bin/env python3
# A UDP relay that loses packets on demand, for SRT loss tests (docs/COLOR_MANAGEMENT_FINDINGS.md §6.10,
# Stage 4). Manifold dials <listen>; the relay forwards to <upstream> (the ffmpeg listener) and back.
#   python3 -I lossrelay.py <listen port> <upstream port>
# SIGUSR1 starts an outage: every packet in BOTH directions is dropped. SIGUSR2 ends it and prints one
# line: the outage's length and what was dropped each way. An outage longer than the SRT latency
# (Manifold's 120 ms) cannot be repaired by retransmission, so it reaches the demuxer as lost TS packets.
# No admin rights, no system network settings: only this socket pair is affected.
import select, signal, socket, sys, time

listen_port, upstream_port = int(sys.argv[1]), int(sys.argv[2])
down = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)   # faces Manifold
down.bind(("127.0.0.1", listen_port))
up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)     # faces the listener
up.connect(("127.0.0.1", upstream_port))
for s in (down, up):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)

state = {"dropping": False, "began": 0.0, "to_up": 0, "to_down": 0}
totals = {"forwarded": 0, "dropped": 0}

def stamp():
    t = time.time()
    return time.strftime("%H:%M:%S", time.localtime(t)) + ".%03d" % int((t % 1) * 1000)

def start(*_):
    state.update(dropping=True, began=time.time(), to_up=0, to_down=0)

def stop(*_):
    if not state["dropping"]:
        return
    state["dropping"] = False
    ms = (time.time() - state["began"]) * 1000
    print(f"{stamp()} outage {ms:.0f} ms: dropped {state['to_up']} packets Manifold→listener, "
          f"{state['to_down']} listener→Manifold", flush=True)

def finish(*_):
    print(f"{stamp()} relay end: {totals['forwarded']} forwarded, {totals['dropped']} dropped", flush=True)
    sys.exit(0)

signal.signal(signal.SIGUSR1, start)
signal.signal(signal.SIGUSR2, stop)
signal.signal(signal.SIGTERM, finish)
print(f"{stamp()} relay 127.0.0.1:{listen_port} → 127.0.0.1:{upstream_port}", flush=True)

client = None
while True:
    try:
        ready, _, _ = select.select([down, up], [], [], 1.0)
    except InterruptedError:
        continue
    for s in ready:
        try:
            data, addr = s.recvfrom(65536)
        except (BlockingIOError, InterruptedError, ConnectionRefusedError):
            continue   # the listener not up yet: SRT's caller retries its handshake
        if s is down:
            client = addr
            if state["dropping"]:
                state["to_up"] += 1; totals["dropped"] += 1
                continue
            try:
                up.send(data)
            except ConnectionRefusedError:
                continue
        else:
            if client is None:
                continue
            if state["dropping"]:
                state["to_down"] += 1; totals["dropped"] += 1
                continue
            down.sendto(data, client)
        totals["forwarded"] += 1
