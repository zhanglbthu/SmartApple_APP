#!/usr/bin/env python3
"""Receive Sensor Read NDJSON UDP packets and optionally save them."""
import argparse
import json
import socket
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="0.0.0.0")
parser.add_argument("--port", type=int, default=9000)
parser.add_argument("--output", type=Path)
args = parser.parse_args()

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((args.host, args.port))
output = args.output.open("ab") if args.output else None
print(f"Listening on udp://{args.host}:{args.port}")
try:
    while True:
        packet, sender = sock.recvfrom(65535)
        for line in packet.splitlines():
            try:
                event = json.loads(line)
                print(sender, event["source"], event["sensor"], event["values"])
                if output:
                    output.write(line + b"\n")
                    output.flush()
            except (json.JSONDecodeError, KeyError) as error:
                print("Invalid packet:", error)
except KeyboardInterrupt:
    print("\nStopped.")
finally:
    if output:
        output.close()
    sock.close()
