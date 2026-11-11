#!/usr/bin/env python3
"""Generate the CHROMEX extension test corpus.

Every fixture is written twice: as an unpacked directory (for the Linux QA harness)
and as a ZIP (for the import pipeline and CI tests).

    python3 Scripts/make_fixtures.py
"""
from __future__ import annotations

import json
import pathlib
import shutil
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
QA = ROOT / "QA"
FIXTURES = QA / "fixtures"
ZIPS = FIXTURES / "zips"


def manifest(**overrides):
    base = {
        "manifest_version": 3,
        "name": "CHROMEX Fixture",
        "version": "1.0.0",
        "description": "CHROMEX QA fixture",
    }
    base.update(overrides)
    return base


FIXTURES_DATA: dict[str, dict] = {
    "basic-content": {
        "manifest": manifest(
            name="Basic Content Script",
            content_scripts=[{
                "matches": ["https://example.com/*"],
                "js": ["content.js"],
                "run_at": "document_end",
            }],
            permissions=["storage"],
        ),
        "files": {
            "content.js": "document.documentElement.dataset.chromexBasic = '1';\n",
        },
    },
    "dark-mode": {
        "manifest": manifest(
            name="Dark Mode",
            content_scripts=[{
                "matches": ["<all_urls>"],
                "css": ["dark.css"],
                "js": ["dark.js"],
                "run_at": "document_start",
            }],
        ),
        "files": {
            "dark.css": "html{background:#0b0b0f !important;color:#e8e8ef !important;}\n",
            "dark.js": "document.documentElement.dataset.chromexDark = '1';\n",
        },
    },
    "ad-blocker": {
        "manifest": manifest(
            name="Rule Blocker",
            permissions=["declarativeNetRequest"],
            host_permissions=["<all_urls>"],
            declarative_net_request={"rule_resources": [
                {"id": "ruleset", "enabled": True, "path": "rules.json"}
            ]},
            content_scripts=[{"matches": ["<all_urls>"], "js": ["hide.js"]}],
        ),
        "files": {
            "rules.json": json.dumps([{"id": 1, "priority": 1, "action": {"type": "block"},
                                       "condition": {"urlFilter": "||ads.example^"}}]),
            "hide.js": "document.documentElement.dataset.chromexBlocker = '1';\n",
        },
    },
    "popup": {
        "manifest": manifest(
            name="Popup",
            action={"default_popup": "popup.html", "default_title": "Popup"},
            permissions=["storage"],
        ),
        "files": {
            "popup.html": "<!doctype html><html><body><h1>CHROMEX popup</h1>"
                          "<script src=\"popup.js\"></script></body></html>\n",
            "popup.js": "chrome.storage.local.get(null, function(v){document.title='popup-ok';});\n",
        },
    },
    "storage": {
        "manifest": manifest(
            name="Storage",
            permissions=["storage"],
            background={"service_worker": "sw.js"},
        ),
        "files": {
            "sw.js": "chrome.storage.local.set({installed:true}, function(){});\n",
        },
    },
    "messaging": {
        "manifest": manifest(
            name="Messaging",
            permissions=["storage"],
            content_scripts=[{"matches": ["https://example.com/*"], "js": ["content.js"]}],
            background={"service_worker": "sw.js"},
        ),
        "files": {
            "content.js": "chrome.runtime.sendMessage({ping:1}, function(r){"
                          "document.title = r && r.pong ? 'pong' : 'no-pong';});\n",
            "sw.js": "chrome.runtime.onMessage.addListener(function(m, s, respond){"
                     "if(m && m.ping){respond({pong:true});} return true;});\n",
        },
    },
    "background-mv2": {
        "manifest": manifest(
            manifest_version=2,
            name="Legacy Background",
            permissions=["storage", "https://example.com/*"],
            background={"scripts": ["bg.js"], "persistent": False},
            browser_action={"default_popup": "popup.html"},
        ),
        "files": {
            "bg.js": "chrome.storage.local.set({legacy:true}, function(){});\n",
            "popup.html": "<!doctype html><html><body>legacy</body></html>\n",
        },
    },
    "permission-restricted": {
        "manifest": manifest(
            name="Narrow Access",
            host_permissions=["https://allowed.example.com/*"],
            content_scripts=[{
                "matches": ["https://allowed.example.com/*"],
                "js": ["content.js"],
            }],
        ),
        "files": {"content.js": "1;\n"},
    },
    "unsupported-api": {
        "manifest": manifest(
            name="Needs Unavailable APIs",
            permissions=["alarms", "cookies"],
            content_scripts=[{"matches": ["https://example.com/*"], "js": ["content.js"]}],
        ),
        "files": {"content.js": "1;\n"},
    },
    "broad-access": {
        "manifest": manifest(
            name="All Sites",
            host_permissions=["<all_urls>"],
            content_scripts=[{"matches": ["<all_urls>"], "js": ["content.js"]}],
        ),
        "files": {"content.js": "1;\n"},
    },
    "malformed": {
        "manifest_raw": "{ this is not json ",
        "files": {"manifest.json": "{ this is not json "},
    },
    "missing-manifest": {
        "manifest": None,
        "files": {"readme.txt": "no manifest here\n"},
    },
}

MALICIOUS_ENTRIES = {
    "manifest.json": json.dumps(manifest(
        name="Malicious Traversal",
        content_scripts=[{"matches": ["<all_urls>"], "js": ["evil.js"]}],
    )),
    "evil.js": "1;\n",
    "../../escaped.txt": "this file must never be written outside the extraction root\n",
}


def write_fixture(name: str, spec: dict) -> None:
    directory = FIXTURES / name
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    for relative, contents in spec.get("files", {}).items():
        target = directory / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents, encoding="utf-8")
    if spec.get("manifest") is not None:
        (directory / "manifest.json").write_text(
            json.dumps(spec["manifest"], indent=2) + "\n", encoding="utf-8"
        )


def zip_fixture(name: str) -> None:
    source = FIXTURES / name
    ZIPS.mkdir(parents=True, exist_ok=True)
    archive = ZIPS / f"{name}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(source).as_posix())


def write_malicious() -> None:
    directory = FIXTURES / "malicious-traversal"
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    for name in ("manifest.json", "evil.js"):
        (directory / name).write_text(MALICIOUS_ENTRIES[name], encoding="utf-8")

    ZIPS.mkdir(parents=True, exist_ok=True)
    archive = ZIPS / "malicious-traversal.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        bundle.writestr("manifest.json", MALICIOUS_ENTRIES["manifest.json"])
        bundle.writestr("evil.js", MALICIOUS_ENTRIES["evil.js"])
        # Deliberately hostile: escapes the extraction root.
        bundle.writestr("../../escaped.txt", MALICIOUS_ENTRIES["../../escaped.txt"])


def main() -> None:
    FIXTURES.mkdir(parents=True, exist_ok=True)
    for name, spec in FIXTURES_DATA.items():
        write_fixture(name, spec)
        zip_fixture(name)
    write_malicious()

    count = len(list(ZIPS.glob("*.zip")))
    print(f"wrote {len(FIXTURES_DATA)} fixtures and {count} archives to {FIXTURES}")


if __name__ == "__main__":
    main()
