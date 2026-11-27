#!/usr/bin/env python3
"""The Pi side of the Snag web page (http://snag.adgoose).

The page asks this server to run yt-dlp. Finished files are kept on the Pi
in MEDIA/Music and MEDIA/Videos, and the page downloads them to whatever
device you're using. Apache serves the page itself and passes /api/ here.

Endpoints (all JSON unless noted):
  POST /api/run          {args}             title lookup or YouTube search
  POST /api/download     {id, url, args, kind}  start a download (same id = same download)
  GET  /api/job/<id>                        progress, error and finished files
  POST /api/cancel/<id>
  GET  /api/file/<id>/<n>                   the file itself, as a download
  GET  /api/version                         yt-dlp version
  POST /api/update                          update yt-dlp
  POST /api/proxy        {method, url, headers, body}   Spotify only

Only yt-dlp options the app actually uses are accepted, so the page can't
be used to run anything else on the Pi. Uses the Python standard library;
yt-dlp is installed with pip into the same virtual environment, and needs
ffmpeg and deno on the PATH (see SETUP.md).
"""

import json
import mimetypes
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("SNAG_HOST", "127.0.0.1")
PORT = int(os.environ.get("SNAG_PORT", "8790"))
MEDIA = os.environ.get("SNAG_MEDIA", "/srv/snag")
STATE = os.path.join(MEDIA, ".snag")
JOBS_FILE = os.path.join(STATE, "jobs.json")
YT_DLP = [sys.executable, "-m", "yt_dlp"]
# Jobs older than this drop off the list. The files themselves stay.
KEEP_JOBS_DAYS = 60

# yt-dlp options the app sends, and how many values each one takes.
OPTIONS = {
    "--no-mtime": 0, "--windows-filenames": 0, "--yes-playlist": 0, "--no-playlist": 0,
    "-x": 0, "--embed-metadata": 0, "--embed-thumbnail": 0, "--write-subs": 0, "--embed-subs": 0,
    "-f": 1, "--audio-format": 1, "--audio-quality": 1, "--convert-thumbnails": 1, "--ppa": 1,
    "-S": 1, "--merge-output-format": 1, "--remux-video": 1, "--sub-langs": 1, "--parse-metadata": 1,
    "-o": 1, "--replace-in-metadata": 3,
}
# The only --ppa the app uses: crop the cover art square.
CROP = "ThumbnailsConvertor:-qmin 1 -q:v 1 -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""
LOOKUP = ["--dump-single-json", "--flat-playlist", "--no-warnings"]
SPOTIFY_HOSTS = {"open.spotify.com", "accounts.spotify.com", "api.spotify.com", "spotify.link"}
JOB_ID = re.compile(r"^[A-Za-z0-9-]{1,64}$")

jobs = {}
processes = {}
lock = threading.Lock()


def save_jobs():
    with lock:
        data = {k: {x: y for x, y in v.items() if x != "progress"} for k, v in jobs.items()}
    os.makedirs(STATE, exist_ok=True)
    with open(JOBS_FILE + ".tmp", "w") as f:
        json.dump(data, f)
    os.replace(JOBS_FILE + ".tmp", JOBS_FILE)


def load_jobs():
    try:
        with open(JOBS_FILE) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return
    cutoff = time.time() - KEEP_JOBS_DAYS * 86400
    for job_id, job in saved.items():
        if job.get("created", 0) < cutoff:
            continue
        # Anything still running when the server stopped didn't finish.
        if job["state"] in ("queued", "running"):
            job.update(state="failed", error="The Pi restarted during this download. Try it again.")
        job["progress"] = 0
        jobs[job_id] = job


def is_link(text):
    return re.match(r"^https?://", text or "") is not None


def check_download_args(args):
    """Returns an error message, or None if every option is one the app uses."""
    i = 0
    while i < len(args):
        flag = args[i]
        if flag not in OPTIONS:
            return f"Option not allowed: {flag}"
        values = args[i + 1:i + 1 + OPTIONS[flag]]
        if len(values) != OPTIONS[flag]:
            return f"Missing value for {flag}"
        if flag == "--ppa" and values[0] != CROP:
            return "That --ppa isn't allowed"
        if flag == "-o" and (values[0].startswith(("/", "~", "\\")) or ".." in values[0].replace("\\", "/").split("/")):
            return "Output names can't leave the Snag folder"
        i += 1 + OPTIONS[flag]
    return None


def last_error(text):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    errors = [l for l in lines if "ERROR" in l]
    return errors[-1] if errors else (lines[-1] if lines else "yt-dlp failed")


def run_download(job_id, url, args, folder):
    temp = os.path.join(STATE, "tmp", job_id)
    cmd = YT_DLP + ["--ignore-config", "--cache-dir", os.path.join(STATE, "cache")] + args + [
        "-P", folder, "-P", f"temp:{temp}",
        "--print", "after_move:filepath",
        "--progress", "--newline",
        "--progress-template", "download:SNAG %(progress._percent_str)s|%(info.playlist_index)s|%(info.n_entries)s",
        "--", url,
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
                            errors="replace")
    with lock:
        processes[job_id] = proc
        jobs[job_id]["state"] = "running"
    errors = []
    reader = threading.Thread(target=lambda: errors.append(proc.stderr.read()), daemon=True)
    reader.start()
    paths = []
    for line in proc.stdout:
        line = line.strip()
        if line.startswith("SNAG "):
            parts = line[5:].split("|")
            try:
                percent = float(parts[0].replace("%", "").strip())
            except ValueError:
                percent = -1
            with lock:
                if percent >= 0:
                    jobs[job_id]["progress"] = percent
                if len(parts) == 3 and parts[2] != "NA":
                    jobs[job_id]["detail"] = f"Item {parts[1]} of {parts[2]}"
        elif line:
            paths.append(line)
    code = proc.wait()
    reader.join()
    subprocess.run(["rm", "-rf", temp])

    with lock:
        processes.pop(job_id, None)
        job = jobs[job_id]
        if job.get("cancelled"):
            job.update(state="cancelled", error="Cancelled")
        elif code != 0:
            job.update(state="failed", error=last_error("".join(errors)))
        else:
            files = []
            for p in paths:
                if os.path.isfile(p):
                    files.append({"name": os.path.basename(p), "path": p, "size": os.path.getsize(p),
                                  "folder": os.path.relpath(os.path.dirname(p), MEDIA)})
            if files:
                job.update(state="done", files=files, progress=100)
            else:
                job.update(state="failed", error="yt-dlp finished but no file came out")
    save_jobs()


# yt-dlp swaps characters Windows can't have in names (/ : ? etc.) for look-alikes
# such as ⧸ and ：. Browsers treat those as suspicious and save the file as just
# "download", so the copy sent to the browser gets plain ones instead.
LOOKALIKES = str.maketrans({"⧸": "-", "⧹": "-", "：": " -", "？": "", "＂": "'", "＊": "", "＜": "", "＞": "", "｜": "-"})


def browser_name(name):
    return re.sub(r"\s+", " ", name.translate(LOOKALIKES)).strip()


def public_job(job_id, job):
    """What the page sees: no full paths on the Pi, just download links."""
    files = [{"name": browser_name(f["name"]), "size": f["size"], "folder": f["folder"],
              "mime": ("audio/" if job["kind"] == "audio" else "video/") + f["name"].rsplit(".", 1)[-1].lower(),
              "url": f"/api/file/{job_id}/{n}"} for n, f in enumerate(job.get("files", []))]
    return {"id": job_id, "state": job["state"], "progress": job.get("progress", 0), "detail": job.get("detail", ""),
            "error": job.get("error", ""), "files": files}


class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/version":
            out = subprocess.run(YT_DLP + ["--version"], capture_output=True, text=True)
            return self.reply(200, {"version": out.stdout.strip()})

        m = re.match(r"^/api/job/([A-Za-z0-9-]+)$", path)
        if m:
            with lock:
                job = jobs.get(m[1])
                return self.reply(200, public_job(m[1], job)) if job else self.reply(404, {"error": "No such download"})

        m = re.match(r"^/api/file/([A-Za-z0-9-]+)/(\d+)$", path)
        if m:
            with lock:
                job = jobs.get(m[1])
                files = job.get("files", []) if job else []
            n = int(m[2])
            if n >= len(files) or not os.path.isfile(files[n]["path"]):
                return self.reply(404, {"error": "That file isn't on the Pi any more"})
            f = files[n]
            self.send_response(200)
            self.send_header("Content-Type", mimetypes.guess_type(f["name"])[0] or "application/octet-stream")
            self.send_header("Content-Length", str(os.path.getsize(f["path"])))
            # Plain name for old browsers, then the full UTF-8 one.
            name = browser_name(f["name"])
            plain = re.sub(r"[^A-Za-z0-9 ._()-]", "_", name)
            self.send_header("Content-Disposition",
                             f"attachment; filename=\"{plain}\"; filename*=UTF-8''{urllib.parse.quote(name)}")
            self.end_headers()
            with open(f["path"], "rb") as src:
                while chunk := src.read(1024 * 1024):
                    self.wfile.write(chunk)
            return None
        return self.reply(404, {"error": "Not found"})

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        data = self.body()

        if path == "/api/run":
            # Only the two lookups the page makes: a link's details, or a YouTube search.
            args = data.get("args") or []
            target = args[-1] if args else ""
            allowed = args[:-1] == LOOKUP + ["--no-playlist"] and is_link(target) or \
                args[:-1] == LOOKUP and re.match(r"^ytsearch\d{1,2}:", target)
            if not allowed:
                return self.reply(400, {"error": "Only link lookups and searches are allowed"})
            out = subprocess.run(YT_DLP + ["--ignore-config", "--cache-dir", os.path.join(STATE, "cache")] + args[:-1]
                                 + ["--", target], capture_output=True, text=True, encoding="utf-8", errors="replace")
            if out.returncode != 0:
                return self.reply(500, {"error": last_error(out.stderr)})
            return self.reply(200, {"out": out.stdout})

        if path == "/api/download":
            job_id, url, args, kind = data.get("id", ""), data.get("url", ""), data.get("args") or [], data.get("kind")
            if not JOB_ID.match(job_id) or not is_link(url) or kind not in ("audio", "video"):
                return self.reply(400, {"error": "Bad download request"})
            problem = check_download_args(args)
            if problem:
                return self.reply(400, {"error": problem})
            with lock:
                # Asking again for the same id (e.g. after a page reload) just
                # returns the download that's already going.
                if job_id in jobs:
                    return self.reply(200, public_job(job_id, jobs[job_id]))
                jobs[job_id] = {"url": url, "kind": kind, "state": "queued", "progress": 0, "created": time.time()}
            folder = os.path.join(MEDIA, "Music" if kind == "audio" else "Videos")
            threading.Thread(target=run_download, args=(job_id, url, args, folder), daemon=True).start()
            with lock:
                return self.reply(200, public_job(job_id, jobs[job_id]))

        m = re.match(r"^/api/cancel/([A-Za-z0-9-]+)$", path)
        if m:
            with lock:
                proc = processes.get(m[1])
                if m[1] in jobs:
                    jobs[m[1]]["cancelled"] = True
            if proc:
                proc.terminate()
            return self.reply(200, {"ok": True})

        if path == "/api/update":
            out = subprocess.run([sys.executable, "-m", "pip", "install", "-U", "yt-dlp"], capture_output=True, text=True)
            if out.returncode != 0:
                return self.reply(500, {"error": last_error(out.stderr)})
            changed = "Successfully installed" in out.stdout
            return self.reply(200, {"status": "DONE" if changed else "ALREADY_UP_TO_DATE"})

        if path == "/api/proxy":
            # Browsers can't read Spotify's pages or API directly, so the page
            # asks through here. Spotify addresses only.
            url = data.get("url", "")
            if urllib.parse.urlparse(url).hostname not in SPOTIFY_HOSTS or not url.startswith("https://"):
                return self.reply(400, {"error": "Only Spotify links can be fetched"})
            body = data.get("body")
            request = urllib.request.Request(url, data=body.encode() if body is not None else None,
                                             headers=data.get("headers") or {}, method=data.get("method", "GET"))
            request.add_header("User-Agent", "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile")
            try:
                with urllib.request.urlopen(request, timeout=20) as res:
                    return self.reply(200, {"status": res.status, "body": res.read().decode("utf-8", "replace")})
            except urllib.error.HTTPError as e:
                return self.reply(200, {"status": e.code, "body": e.read().decode("utf-8", "replace")})
            except OSError as e:
                return self.reply(502, {"error": str(e)})

        return self.reply(404, {"error": "Not found"})

    def log_message(self, fmt, *args):
        # Progress polling is noisy; only log problems.
        if args and str(args[1])[:1] in "45":
            super().log_message(fmt, *args)


if __name__ == "__main__":
    for sub in ("Music", "Videos", ".snag/tmp"):
        os.makedirs(os.path.join(MEDIA, sub), exist_ok=True)
    load_jobs()
    print(f"Snag server on http://{HOST}:{PORT}, files in {MEDIA}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
