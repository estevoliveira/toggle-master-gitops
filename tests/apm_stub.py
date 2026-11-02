"""Substitui somente a conta comercial no teste; nao e usado no EKS."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json

count = 0


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        global count
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/v1/traces':
            count += 1
        self.send_response(200)
        self.send_header('Content-Type', 'application/x-protobuf')
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps({'traces': count}).encode())


HTTPServer(('0.0.0.0', 9000), Handler).serve_forever()
