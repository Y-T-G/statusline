param(
    [switch]$Uninstall,
    [string]$Mode = "minimal",
    [switch]$UsageApi
)

$ErrorActionPreference = "Stop"

$claudeDir = [Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR")
if (-not $claudeDir) { $claudeDir = Join-Path $env:USERPROFILE ".claude" }
$settingsPath = Join-Path $claudeDir "settings.json"

if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir | Out-Null }
if (-not (Test-Path $settingsPath)) { "{}" | Set-Content $settingsPath }

if ($Uninstall) {
    Copy-Item -Path $settingsPath -Destination "$settingsPath.bak" -Force
    $json = Get-Content $settingsPath | ConvertFrom-Json
    if ($json.PSObject.Properties.Match("statusLine").Count -gt 0) {
        $json.PSObject.Properties.Remove("statusLine")
    }
    $json | ConvertTo-Json -Depth 20 | Set-Content $settingsPath
    Write-Host "removed statusLine from $settingsPath (backup: $settingsPath.bak)"
    exit 0
}

# Always install a copy of statusline.ps1 into the config dir.
# The config dir (~/.gemini/antigravity-cli or ~/.claude) has no spaces, so
# the path can be used unquoted in the command string. This avoids the
# "Illegal characters in path" error that occurs when the CLI wraps the
# command value in an extra layer of quotes around an already-quoted path.
$destScript = Join-Path $claudeDir "statusline.ps1"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localScript = Join-Path $scriptDir "statusline.ps1"

if (Test-Path $localScript) {
    Copy-Item -Path $localScript -Destination $destScript -Force
    Write-Host "Copied statusline.ps1 to $destScript"
} else {
    Write-Host "Downloading statusline.ps1 to $destScript..."
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/Y-T-G/statusline/main/statusline.ps1" -OutFile $destScript
}

Copy-Item -Path $settingsPath -Destination "$settingsPath.bak" -Force

$argsStr = ""
if ($Mode -eq "full") { $argsStr += " -Mode full" }
if ($UsageApi) { $argsStr += " -UsageApi" }

# Unquoted path is safe here because $claudeDir contains no spaces.
$cmdStr = "powershell -NoProfile -ExecutionPolicy Bypass -File $destScript$argsStr"

$json = Get-Content $settingsPath | ConvertFrom-Json
if (-not $json) { $json = [PSCustomObject]@{} }
$json | Add-Member -MemberType NoteProperty -Name "statusLine" -Value ([PSCustomObject]@{
    type = "command"
    command = $cmdStr
    refreshInterval = 30
}) -Force

$json | ConvertTo-Json -Depth 20 | Set-Content $settingsPath

$usageMsg = ""
if ($UsageApi) { $usageMsg = " with usage-api" }
Write-Host "installed $Mode mode$usageMsg in $settingsPath (backup: $settingsPath.bak)"

# Preview
$previewJson = @{
    model = @{ display_name = "Opus 5" }
    workspace = @{ current_dir = $env:USERPROFILE }
    cost = @{ total_cost_usd = 1.23 }
    context_window = @{ total_input_tokens = 45231; context_window_size = 1000000; used_percentage = 4.5 }
    rate_limits = @{
        five_hour = @{ used_percentage = 22; resets_at = [DateTime]::UtcNow.AddSeconds(9000).ToString("o") }
        seven_day = @{ used_percentage = 7; resets_at = [DateTime]::UtcNow.AddSeconds(400000).ToString("o") }
    }
} | ConvertTo-Json -Depth 10 -Compress

Write-Host -NoNewline "preview: "
$previewJson | powershell -NoProfile -ExecutionPolicy Bypass -File $destScript -Mode $Mode
Write-Host ""
