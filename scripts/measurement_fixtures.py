"""Synthetic measurement fixtures for the emulator and iOS runs of the nine
registered measurements.

Started by scripts/android-measurement-fixtures.sh, which redirects the
emulator's traffic for the fixture address to these listeners on the host's
loopback interface (the emulator reaches it as 10.0.2.2), or by
scripts/ios-measurement-fixtures.sh, which serves them on the host's global
IPv6 address on the standard ports and answers only peers of the host's own
on-link prefix. Every listener answers with fixed synthetic content and
records nothing:

  DNS   UDP and TCP: an A query is answered with the fixture address, any other
        query with an empty answer.
  HTTP  GET /generate_204 answers 204, anything else 404.
  HTTPS GET /fixture answers 200 with a short body; POST /dns-query with an
        application/dns-message body answers it as DNS over HTTPS; a client that
        sends nothing after the handshake (TLS-01, TCP-01) is closed.
  DoT   one length-prefixed DNS exchange over TLS.

Usage: python3 measurement_fixtures.py --cert leaf.pem --key leaf-key.pem
       --address 8.8.8.8 [--answer IPV4] [--listen HOST] [--allow NETWORK ...]
       [--dns PORT] [--http PORT] [--https PORT] [--dot PORT]

--answer is the IPv4 address of every A answer (the fixture address when that
is IPv4). --listen "::" listens on every IPv6 address; --allow then limits the
peers that are answered to the given networks, and any other peer is closed
without an answer.
"""

import argparse
import ipaddress
import socket
import socketserver
import ssl
import struct
import threading

HOST = "127.0.0.1"
FIXTURE_BODY = b"barometer synthetic fixture\n"


def dns_answer(query: bytes, address: bytes) -> bytes | None:
    """Returns the response to one DNS query, or None for a malformed one."""
    if len(query) < 12:
        return None
    ident, flags, qdcount = struct.unpack("!HHH", query[:6])
    if flags & 0x8000 or qdcount != 1:
        return None
    end = 12
    while True:
        if end >= len(query):
            return None
        length = query[end]
        if length & 0xC0:
            return None
        end += 1 + length
        if length == 0:
            break
    if end + 4 > len(query):
        return None
    qtype, qclass = struct.unpack("!HH", query[end : end + 4])
    question = query[12 : end + 4]
    answers = b""
    if qtype == 1 and qclass == 1:
        answers = struct.pack("!HHHIH", 0xC00C, 1, 1, 300, 4) + address
    header = struct.pack(
        "!HHHHHH", ident, 0x8180 | (flags & 0x0100), 1, 1 if answers else 0, 0, 0
    )
    return header + question + answers


def read_exact(stream, n: int) -> bytes | None:
    data = b""
    while len(data) < n:
        chunk = stream.recv(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def read_http_request(conn) -> tuple[str, str, dict, bytes] | None:
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            return None
        data += chunk
        if len(data) > 16384:
            return None
    head, rest = data.split(b"\r\n\r\n", 1)
    lines = head.decode("latin-1").split("\r\n")
    parts = lines[0].split(" ")
    if len(parts) != 3:
        return None
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    length = int(headers.get("content-length", "0") or 0)
    if length > 65535:
        return None
    if len(rest) < length:
        more = read_exact(conn, length - len(rest))
        if more is None:
            return None
        rest += more
    return parts[0], parts[1], headers, rest[:length]


def http_response(status: str, body: bytes = b"", content_type: str = "text/plain") -> bytes:
    head = f"HTTP/1.1 {status}\r\nConnection: close\r\n"
    if body or not status.startswith("204"):
        head += f"Content-Type: {content_type}\r\nContent-Length: {len(body)}\r\n"
    return head.encode() + b"\r\n" + body


class Fixtures:
    def __init__(self, args):
        fixture = ipaddress.ip_address(args.address)
        answer = args.answer or (str(fixture) if fixture.version == 4 else None)
        if answer is None:
            raise SystemExit("--answer is required with an IPv6 fixture address")
        self.address = ipaddress.IPv4Address(answer).packed
        self.allow = [ipaddress.ip_network(n) for n in args.allow]
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.minimum_version = ssl.TLSVersion.TLSv1_2
        self.tls.load_cert_chain(args.cert, args.key)
        self.tls.set_alpn_protocols(["http/1.1"])
        self.args = args

    def allowed(self, peer) -> bool:
        if not self.allow:
            return True
        address = ipaddress.ip_address(peer[0].split("%")[0])
        return any(address in network for network in self.allow)

    def serve(self):
        fixtures = self
        host = self.args.listen
        family = socket.AF_INET6 if ":" in host else socket.AF_INET

        class Threaded(socketserver.ThreadingMixIn, socketserver.TCPServer):
            address_family = family
            allow_reuse_address = True
            daemon_threads = True

            def server_bind(self):
                if family == socket.AF_INET6:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                super().server_bind()

            def verify_request(self, request, client_address):
                return fixtures.allowed(client_address)

        class UDPThreaded(socketserver.ThreadingMixIn, socketserver.UDPServer):
            address_family = family
            allow_reuse_address = True
            daemon_threads = True

            def server_bind(self):
                if family == socket.AF_INET6:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                super().server_bind()

            def verify_request(self, request, client_address):
                return fixtures.allowed(client_address)

        class DNSUDP(socketserver.BaseRequestHandler):
            def handle(self):
                data, sock = self.request
                reply = dns_answer(data, fixtures.address)
                if reply:
                    sock.sendto(reply, self.client_address)

        class DNSTCP(socketserver.BaseRequestHandler):
            def handle(self):
                fixtures.dns_stream(self.request)

        class HTTP(socketserver.BaseRequestHandler):
            def handle(self):
                fixtures.http(self.request, tls=False)

        class HTTPS(socketserver.BaseRequestHandler):
            def handle(self):
                conn = fixtures.wrap(self.request)
                if conn:
                    fixtures.http(conn, tls=True)

        class DoT(socketserver.BaseRequestHandler):
            def handle(self):
                conn = fixtures.wrap(self.request)
                if conn:
                    fixtures.dns_stream(conn)

        servers = [
            UDPThreaded((host, self.args.dns), DNSUDP),
            Threaded((host, self.args.dns), DNSTCP),
            Threaded((host, self.args.http), HTTP),
            Threaded((host, self.args.https), HTTPS),
            Threaded((host, self.args.dot), DoT),
        ]
        for server in servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        print("ready", flush=True)
        threading.Event().wait()

    def wrap(self, sock):
        sock.settimeout(15)
        try:
            return self.tls.wrap_socket(sock, server_side=True)
        except (ssl.SSLError, OSError):
            return None

    def dns_stream(self, conn):
        conn.settimeout(15)
        try:
            prefix = read_exact(conn, 2)
            if prefix is None:
                return
            query = read_exact(conn, struct.unpack("!H", prefix)[0])
            reply = dns_answer(query or b"", self.address)
            if reply:
                conn.sendall(struct.pack("!H", len(reply)) + reply)
        except OSError:
            pass
        finally:
            conn.close()

    def http(self, conn, tls: bool):
        conn.settimeout(15)
        try:
            request = read_http_request(conn)
            if request is None:
                return
            method, path, headers, body = request
            if not tls and method == "GET" and path == "/generate_204":
                conn.sendall(http_response("204 No Content"))
            elif tls and method == "GET" and path == "/fixture":
                conn.sendall(http_response("200 OK", FIXTURE_BODY))
            elif (
                tls
                and method == "POST"
                and path == "/dns-query"
                and headers.get("content-type") == "application/dns-message"
                and (reply := dns_answer(body, self.address))
            ):
                conn.sendall(http_response("200 OK", reply, "application/dns-message"))
            else:
                conn.sendall(http_response("404 Not Found"))
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--address", required=True)
    parser.add_argument("--answer")
    parser.add_argument("--listen", default=HOST)
    parser.add_argument("--allow", action="append", default=[])
    parser.add_argument("--dns", type=int, default=10053)
    parser.add_argument("--http", type=int, default=10080)
    parser.add_argument("--https", type=int, default=10443)
    parser.add_argument("--dot", type=int, default=10853)
    Fixtures(parser.parse_args()).serve()


if __name__ == "__main__":
    socket.setdefaulttimeout(30)
    main()
