#!/usr/bin/env python3
import socket, sys

def ok(p:int)->bool:
    for fam, addr in [(socket.AF_INET,"127.0.0.1"), (socket.AF_INET6,"::")]:
        try:
            s=socket.socket(fam, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((addr,p))
            s.close()
        except OSError:
            return False
    return True

lo = int(sys.argv[1]) if len(sys.argv) >= 2 else 3001
hi = int(sys.argv[2]) if len(sys.argv) >= 3 else 3200

for p in range(lo, hi+1):
    if ok(p):
        print(p)
        raise SystemExit(0)

print(0)
raise SystemExit(1)
