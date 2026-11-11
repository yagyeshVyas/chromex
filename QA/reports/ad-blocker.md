# ad-blocker — compatibility report

**Classification:** Partially compatible — analysis only, runtime untested

| Field | Value |
|---|---|
| Manifest version | 3 |
| Name | Rule Blocker |
| Version | 1.0.0 |
| Declared permissions | declarativeNetRequest |
| Host patterns | <all_urls> |
| Content scripts | 1 |
| Background | none |
| Popup | none |

## Analysis result

- Verdict: `runs-with-limits` — It will run, but some of what it declares is not available on iOS.
- Score: 85/100
- Broad host access: yes
- Supported APIs: content_scripts
- Unsupported APIs: declarativeNetRequest

| API | Status | Note |
|---|---|---|
| declarativeNetRequest | unsupported | Declared but not implemented in this build. |

## Execution results (device required)

| Check | Result |
|---|---|
| Installation | Not run on device — validated at analysis level only |
| Content-script injection | Not run on device |
| Background execution | Not run on device |
| Popup rendering | Not run on device |
| Storage round-trip | Not run on device |
| Runtime errors | Not collected |

> Classification stays at *partially compatible* until these are executed on a signed build.
