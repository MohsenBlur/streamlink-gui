"""Serves an HLS folder on 127.0.0.1, throttled, and dies after N seconds.

usage: python -I dying_hls.py <hls dir> <port> <die after seconds>

Segments trickle out in 128 KiB chunks 0.7s apart (a ~440 KB, 4s segment
takes ~2.8s), so the player holds a realistic buffer instead of swallowing the
whole VOD at once. At the deadline the process exits abruptly, every
connection with it: the stream dies under the player mid-VOD, which is what a
Twitch connection closed during a long pause looks like to it.
"""
import http.server
import os
import socketserver
import sys
import threading
import time

root, port, die_after = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print('%.2f %s' % (time.time() - start, fmt % args), flush=True)

    def do_GET(self):
        name = os.path.basename(self.path.split('?')[0])
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        data = open(path, 'rb').read()
        self.send_response(200)
        self.send_header('Content-Type', 'application/vnd.apple.mpegurl'
                         if name.endswith('.m3u8') else 'video/mp2t')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        if not name.endswith('.ts'):
            self.wfile.write(data)
            return
        for i in range(0, len(data), 131072):
            self.wfile.write(data[i:i + 131072])
            self.wfile.flush()
            time.sleep(0.7)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


start = time.time()
server = Server(('127.0.0.1', port), Handler)


def die():
    time.sleep(die_after)
    print('%.2f *** SERVER KILLED ***' % (time.time() - start), flush=True)
    os._exit(0)


threading.Thread(target=die, daemon=True).start()
server.serve_forever()
