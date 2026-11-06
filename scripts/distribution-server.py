#!/usr/bin/python3
"""Serve only published release files on loopback for Tailscale Serve."""
import argparse
import re
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit


class ReleaseHandler(SimpleHTTPRequestHandler):
    def release_path(self, raw_path):
        path = unquote(urlsplit(raw_path).path)
        if path.startswith('/cleanmoss/'):
            path = path[len('/cleanmoss'):]
        if '\x00' in path or '\\' in path or '..' in path.split('/'):
            return None
        if path not in ('/install.sh', '/release.json') and not re.fullmatch(r'/releases/[a-f0-9]{64}/cleanmoss-macos-universal\.zip', path):
            return None
        root = Path(self.directory).resolve()
        candidate = root.joinpath(path.lstrip('/')).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            return None
        return candidate if candidate.is_file() and not candidate.name.startswith('.') else None

    def translate_path(self, path):
        return str(self.release_path(path) or Path(self.directory) / '.not-found')

    def send_head(self):
        if self.release_path(self.path) is None:
            self.send_error(404, 'Release file not found')
            return None
        return super().send_head()

    def end_headers(self):
        if '/releases/' in self.path:
            self.send_header('Cache-Control', 'public, max-age=31536000, immutable')
        else:
            self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--port', type=int, default=52741)
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error('Release root does not exist; run package-network.sh first.')
    handler = partial(ReleaseHandler, directory=str(args.root.resolve()))
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler)
    print(f'Cleanmoss releases listening on 127.0.0.1:{args.port}', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
