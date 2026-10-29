#!/usr/bin/env python3
"""本地 UDP echo（测试用），监听 0.0.0.0:<port>；只在测试容器的私有网络命名空间中运行。"""
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 9053))
while True:
    d, a = s.recvfrom(65535); s.sendto(d, a)
