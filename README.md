<h1 align="center">statusline</h1>

<p align="center">
  A status line for <a href="https://code.claude.com">Claude Code</a> and <a href="https://antigravity.google">Google Antigravity</a> (agy) that shows which model
  is answering, how much context window you have used, and how much of your plan budget is
  left.
</p>

<p align="center">
  <a href="https://code.claude.com"><img alt="Claude Code" src="https://img.shields.io/badge/Claude%20Code-status%20line-d97757"></a>
  <a href="https://www.gnu.org/software/bash/"><img alt="bash" src="https://img.shields.io/badge/bash-%3E%3D4.0-4eaa25?logo=gnubash&logoColor=white"></a>
  <a href="https://jqlang.github.io/jq/"><img alt="jq" src="https://img.shields.io/badge/requires-jq-1e88e5"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/github/license/Y-T-G/statusline?color=blue"></a>
  <a href="https://github.com/Y-T-G/statusline/stargazers"><img alt="stars" src="https://img.shields.io/github/stars/Y-T-G/statusline?style=flat"></a>
</p>

<p align="center">
  <img alt="minimal mode" src="assets/minimal.png">
</p>

## Highlights

- **The model that is answering.** A mid-session model switch, such as a fallback when a
  weekly window runs out, moves the field on the new model's first reply.
- **Budget left, not just tokens spent.** Percent left and a countdown to reset for every
  window the account reports.
- **Context window** in tokens and percent of the window in use.

<img alt="model switch" src="assets/model-switch.png">

## Modes

| Mode | Fields |
|------|--------|
| `minimal` (default) | model, context window, 5 hour budget left, spend limit left when one applies |
| `full` | model, directory, context window, 5 hour budget left, 7 day budget left, spend limit left, session cost |

<img alt="full mode" src="assets/full.png">

Percentages are colored by how much is used: green below 70%, orange to 90%, red above.

Session cost in USD shows for API key, Bedrock and Vertex usage, and is hidden when the
account reports plan rate limits. `CC_STATUSLINE_COST=1` forces it, `=0` hides it.

## Install

### Windows (PowerShell)

A native PowerShell version (`statusline.ps1`) is provided for Windows users so it runs without needing Bash or `jq`.

#### Claude Code

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Y-T-G/statusline/main/install.ps1" -OutFile "$env:TEMP\install.ps1"; & "$env:TEMP\install.ps1"
```

#### Google Antigravity (`agy`)

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Y-T-G/statusline/main/install.ps1" -OutFile "$env:TEMP\install.ps1"; $env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\.gemini\antigravity-cli"; & "$env:TEMP\install.ps1"
```

To install in `full` mode or with `usage-api`, append the flags to either command above:

```powershell
& "$env:TEMP\install.ps1" -Mode full -UsageApi
```

### Linux / macOS (Bash)

Needs `bash` and `jq`.

#### Claude Code

```bash
curl -fsSL https://raw.githubusercontent.com/Y-T-G/statusline/main/install.sh | bash
```

To install in `full` mode or with `usage-api`:

```bash
curl -fsSL https://raw.githubusercontent.com/Y-T-G/statusline/main/install.sh | bash -s -- full usage-api
```

#### Google Antigravity (`agy`)

This status line natively parses the distinct `quota` schema used by `agy`. To install it, point the installer to the Antigravity config directory:

```bash
curl -fsSL https://raw.githubusercontent.com/Y-T-G/statusline/main/install.sh | CLAUDE_CONFIG_DIR=~/.gemini/antigravity-cli bash
```

*(You can also append `-s -- full` to install full mode).*

### Uninstallation

The installer downloads the statusline script to your config directory and adds a `statusLine` entry to `settings.json`, keeping a backup at `.bak`. To safely remove it:

**Windows (PowerShell):**
```powershell
& "$env:TEMP\install.ps1" -Uninstall
```

**Linux/macOS (Bash):**
```bash
# For Claude Code:
curl -fsSL https://raw.githubusercontent.com/Y-T-G/statusline/main/install.sh | bash -s -- --uninstall

# For Antigravity (agy):
curl -fsSL https://raw.githubusercontent.com/Y-T-G/statusline/main/install.sh | CLAUDE_CONFIG_DIR=~/.gemini/antigravity-cli bash -s -- --uninstall
```

To wire it by hand instead:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"/path/to/statusline/statusline.sh\" minimal",
    "refreshInterval": 30
  }
}
```

`refreshInterval` redraws the countdown. The host CLI redraws on its own when token usage
or the model changes, and the usage fetch below is gated by its cache, so the interval
does not change how many requests go out.

## The Fable weekly window (Claude Code only)

In Claude Code, the payload carries the session and overall weekly windows only. A separately metered
model, today Fable, has its own bar in `/usage`, which comes from the account usage
endpoint. Pass `usage-api` to read it too:

```bash
curl -fsSL https://raw.githubusercontent.com/Y-T-G/statusline/main/install.sh | bash -s -- minimal usage-api
```

<img alt="usage-api mode" src="assets/usage-api.png">

Each window is labeled with its own name and shown only while the account reports it.

This reads the OAuth token from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`) and calls
`GET /api/oauth/usage`, so it needs a subscription login with the token in a file. It does
not work with an API key, or on macOS where the credentials live in the Keychain.

The answer is cached in `~/.cache/statusline/` and refreshed in the
background, so no redraw waits on the network. At most one request is in flight per
machine and the ceiling is 12 an hour, dropping to none while the session is idle. A
failed fetch keeps the old cache and pauses further attempts.

| Variable | Default | Effect |
|----------|---------|--------|
| `CC_STATUSLINE_USAGE_TTL` | 300 | seconds a cached answer is used for |
| `CC_STATUSLINE_USAGE_IDLE` | 900 | seconds of session silence after which fetching stops |
| `CC_STATUSLINE_USAGE_FAIL_TTL` | 1800 | seconds to wait after a failed fetch |

## Where the numbers come from

The host CLI passes a JSON payload to the status line command on stdin. This script reads:

| Field | Used for |
|-------|----------|
| `context_window.total_input_tokens`, `.context_window_size`, `.used_percentage` | the `ctx` field |
| `rate_limits.five_hour` | 5 hour budget left and reset countdown (Claude Code) |
| `quota."gemini-5h"`, `"3p-5h"` | 5 hour budget left and reset countdown (agy) |
| `rate_limits.seven_day` | 7 day budget left and reset countdown (Claude Code) |
| `quota."gemini-weekly"`, `"3p-weekly"` | 7 day budget left and reset countdown (agy) |
| `rate_limits.spend_limit` | spend limit left, present only on gateway overage |
| `cost.total_cost_usd` | session cost |
| `transcript_path` | the model of the last main loop reply |

The budget numbers are the same ones `/usage` reports. Fields the payload does not carry
are skipped, so an API key session (in Claude Code) shows context and cost only.

## Adding your own field

If `~/.claude/statusline-extra.sh` (or `$CLAUDE_CONFIG_DIR/statusline-extra.sh`) exists, it is run with the same JSON on stdin and its
output is appended. On Windows, the PowerShell script looks for `statusline-extra.ps1` instead.

Example that adds the git branch:

**Linux / macOS (Bash):**
```bash
#!/usr/bin/env bash
git branch --show-current 2>/dev/null
```

**Windows (PowerShell):**
```powershell
git branch --show-current 2>$null
```

The screenshots above are generated from real output with `assets/render.py`, which needs `cairosvg`.

## License

MIT
