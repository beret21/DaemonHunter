#!/usr/bin/env python3
"""appcast.xml에 새 릴리즈 항목을 맨 위에 추가한다."""

import argparse
import re
from datetime import datetime, timezone

APPCAST_PATH = "appcast.xml"

def update(url: str, version: str, build: str, size: str, signature: str):
    with open(APPCAST_PATH, "r", encoding="utf-8") as f:
        content = f.read()

    pub_date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    new_item = f"""
        <item>
            <title>Claude Agent Monitor {version}</title>
            <pubDate>{pub_date}</pubDate>
            <enclosure
                url="{url}"
                sparkle:version="{build}"
                sparkle:shortVersionString="{version}"
                length="{size}"
                type="application/octet-stream"
                sparkle:edSignature="{signature}"/>
            <sparkle:minimumSystemVersion>15.1</sparkle:minimumSystemVersion>
        </item>"""

    # Insert after <language> tag
    content = re.sub(
        r"(<language>.*?</language>)",
        r"\1" + new_item,
        content,
        count=1
    )

    with open(APPCAST_PATH, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"✅ appcast.xml updated for {version} (build {build})")

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--url",       required=True)
    p.add_argument("--version",   required=True)
    p.add_argument("--build",     required=True)
    p.add_argument("--size",      required=True)
    p.add_argument("--signature", required=True)
    args = p.parse_args()
    update(args.url, args.version, args.build, args.size, args.signature)
