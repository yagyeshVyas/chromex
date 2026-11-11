# dark-mode — compatibility report

**Classification:** Partially compatible — analysis only, runtime untested

| Field | Value |
|---|---|
| Manifest version | 3 |
| Name | Dark Mode |
| Version | 1.0.0 |
| Declared permissions | none |
| Host patterns | <all_urls> |
| Content scripts | 1 |
| Background | none |
| Popup | none |

## Analysis result

- Verdict: `runs` — Every API this extension declares is implemented by CHROMEX.
- Score: 100/100
- Broad host access: no
- Supported APIs: content_scripts
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
