#!/usr/bin/env python3
"""Minimal Source RCON client.

Config comes from the environment (RCON_HOST, RCON_PORT, RCON_PASSWORD) and the
command from argv, so nothing is interpolated into source text - an RCON
password containing a quote or a backslash is just a string here.

Response body goes to stdout; every diagnostic goes to stderr. Exit codes are
distinct so the caller can log *why* it failed:

    0  ok
    2  auth rejected (bad password, or the address is rcon-banned)
    3  connect failed (DNS, refused, unreachable)
    4  timed out or the server hung up mid-conversation
    5  usage/config error
"""

import os
import socket
import struct
import sys

SERVERDATA_RESPONSE_VALUE = 0
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_AUTH = 3

AUTH_ID = 1
EXEC_ID = 2
SENTINEL_ID = 3

CONNECT_TIMEOUT = 5
READ_TIMEOUT = 10
# How long to keep waiting for more body packets once the server has stopped
# answering but has not echoed the sentinel back.
DRAIN_TIMEOUT = 1.0


class ProtocolError(Exception):
    pass


def recvall(sock, n):
    """Read exactly n bytes. recv() alone returns *up to* n."""
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ProtocolError(
                "connection closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return buf


def send_packet(sock, req_id, pkt_type, body):
    """size = id(4) + type(4) + body + terminator(1) + empty string(1)."""
    payload = body.encode("utf-8")
    size = len(payload) + 10
    sock.sendall(struct.pack("<iii", size, req_id, pkt_type) + payload + b"\x00\x00")


def read_packet(sock):
    size = struct.unpack("<i", recvall(sock, 4))[0]
    if size < 10 or size > 8192:
        raise ProtocolError("implausible packet size %d" % size)
    rest = recvall(sock, size)
    req_id, pkt_type = struct.unpack("<ii", rest[:8])
    return req_id, pkt_type, rest[8:-2].decode("utf-8", "replace")


def authenticate(sock, password):
    send_packet(sock, AUTH_ID, SERVERDATA_AUTH, password)
    # The server answers with an empty SERVERDATA_RESPONSE_VALUE *and then* the
    # SERVERDATA_AUTH_RESPONSE. Reading only one packet leaves the second in the
    # buffer, where it gets mistaken for the reply to the first command.
    for _ in range(4):
        req_id, pkt_type, _body = read_packet(sock)
        if pkt_type != SERVERDATA_AUTH_RESPONSE:
            continue
        if req_id == -1:
            sys.stderr.write("rcon: auth rejected (bad password, or this "
                             "address is rcon-banned)\n")
            sys.exit(2)
        return
    raise ProtocolError("no auth response")


def execute(sock, command):
    send_packet(sock, EXEC_ID, SERVERDATA_EXECCOMMAND, command)
    # `status` is larger than one 4096-byte packet. There is no length field for
    # the whole reply, so the standard trick is to send a second, empty packet:
    # the server processes requests in order, and its echo of the sentinel marks
    # the end of the real response.
    send_packet(sock, SENTINEL_ID, SERVERDATA_RESPONSE_VALUE, "")

    parts = []
    while True:
        try:
            req_id, _pkt_type, body = read_packet(sock)
        except socket.timeout:
            if parts:
                # Server never echoed the sentinel but did answer. Take what we
                # have rather than failing outright.
                break
            raise
        if req_id == SENTINEL_ID:
            break
        parts.append(body)
        # Once the first body packet is in, stop waiting the full read timeout
        # for a sentinel that some builds do not send.
        sock.settimeout(DRAIN_TIMEOUT)
    return "".join(parts)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: rcon.py <command>\n")
        return 5

    host = os.environ.get("RCON_HOST")
    password = os.environ.get("RCON_PASSWORD")
    if not host or not password:
        sys.stderr.write("rcon: RCON_HOST and RCON_PASSWORD must be set\n")
        return 5
    try:
        port = int(os.environ.get("RCON_PORT", "27015"))
    except ValueError:
        sys.stderr.write("rcon: RCON_PORT is not a number\n")
        return 5

    command = " ".join(sys.argv[1:])

    try:
        sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    except socket.timeout:
        sys.stderr.write("rcon: timed out connecting to %s:%d\n" % (host, port))
        return 4
    except OSError as exc:
        sys.stderr.write("rcon: cannot connect to %s:%d: %s\n" % (host, port, exc))
        return 3

    try:
        sock.settimeout(READ_TIMEOUT)
        authenticate(sock, password)
        sys.stdout.write(execute(sock, command))
    except socket.timeout:
        sys.stderr.write("rcon: timed out waiting for %s:%d\n" % (host, port))
        return 4
    except (ProtocolError, OSError) as exc:
        sys.stderr.write("rcon: %s\n" % exc)
        return 4
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
