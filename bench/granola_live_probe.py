# /// script
# dependencies = []
# ///
"""Is a live transcript reachable through the Granola public API while a meeting runs?

Polls notes updated in the last 3 hours and, for each, counts transcript items and
the newest item time. Appends one JSON line per poll to OUT. Prints no credentials.
Usage: GRANOLA_API_KEY=... uv run bench/granola_live_probe.py OUT.jsonl [polls] [interval_s]
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://public-api.granola.ai/v1"


def get(path: str, params: dict | None = None) -> dict:
    url = API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + os.environ["GRANOLA_API_KEY"]})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"http_error": e.code}


def poll() -> dict:
    since = (datetime.now(timezone.utc) - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
    listing = get("/notes", {"updated_after": since})
    notes = []
    for n in listing.get("notes", []):
        tr = get(f"/notes/{n['id']}/transcript", {"page_size": 100})
        items = tr.get("transcript") or []
        notes.append({
            "id": n["id"], "title": n.get("title"), "created_at": n.get("created_at"), "updated_at": n.get("updated_at"),
            "transcript_error": tr.get("http_error"), "transcript_items_first_page": len(items),
            "has_more": tr.get("hasMore"), "last_item": {k: items[-1].get(k) for k in ("start_time", "end_time", "source")} if items else None,
        })
    return {"ts": datetime.now(timezone.utc).isoformat(), "list_error": listing.get("http_error"), "notes": notes}


def main() -> None:
    out, polls, interval = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 1, int(sys.argv[3]) if len(sys.argv) > 3 else 120
    for i in range(polls):
        with open(out, "a") as f:
            f.write(json.dumps(poll()) + "\n")
        if i + 1 < polls:
            time.sleep(interval)


if __name__ == "__main__":
    main()
