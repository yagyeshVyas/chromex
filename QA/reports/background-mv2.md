# background-mv2 — compatibility report

**Classification:** Partially compatible — analysis only, runtime untested

| Field | Value |
|---|---|
| Manifest version | 2 |
| Name | Legacy Background |
| Version | 1.0.0 |
| Declared permissions | storage |
| Host patterns | https://example.com/* |
| Content scripts | 0 |
| Background | scripts |
| Popup | popup.html |

## Analysis result

- Verdict: `runs` — Every API this extension declares is implemented by CHROMEX.
- Score: 100/100
- Broad host access: no
- Supported APIs: action, background
- Unsupported APIs: none

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
