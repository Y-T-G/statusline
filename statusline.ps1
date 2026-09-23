param(
    [string]$Mode = "minimal"
)

# Read JSON from stdin
$inputString = $input | Out-String
if ([string]::IsNullOrWhiteSpace($inputString)) { exit }
$inputJson = $inputString | ConvertFrom-Json

# Environment variables
$modeEnv = [Environment]::GetEnvironmentVariable("CC_STATUSLINE_MODE")
if ($modeEnv) { $Mode = $modeEnv }

$usageApiEnv = [Environment]::GetEnvironmentVariable("CC_STATUSLINE_USAGE_API")
$usageApi = if ($usageApiEnv -eq "1" -or $args -contains "usage-api") { $true } else { $false }

$costEnv = [Environment]::GetEnvironmentVariable("CC_STATUSLINE_COST")
$costSetting = if ($costEnv) { $costEnv } else { "auto" }

$claudeDir = [Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR")
if (-not $claudeDir) { $claudeDir = Join-Path $env:USERPROFILE ".claude" }

# 1. Transcript last model
$lastModel = ""
$transcriptPath = $inputJson.transcript_path
if (-not $transcriptPath -and $inputJson.session_id) {
    $session = $inputJson.session_id
    $projDir = Join-Path $claudeDir "projects"
    if (Test-Path $projDir) {
        $recentFile = Get-ChildItem -Path $projDir -Filter "$session.jsonl" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($recentFile) { $transcriptPath = $recentFile.FullName }
    }
}

if ($transcriptPath -and (Test-Path $transcriptPath)) {
    # Read last 256KB roughly to avoid reading huge files fully
    $fs = [System.IO.File]::OpenRead($transcriptPath)
    $seekPos = [math]::Max(0, $fs.Length - 262144)
    $fs.Seek($seekPos, [System.IO.SeekOrigin]::Begin) | Out-Null
    $reader = New-Object System.IO.StreamReader($fs)
    $content = $reader.ReadToEnd()
    $reader.Close()
    
    $matches = [regex]::Matches($content, '"type":"assistant".*?(?<!"isSidechain":true.*?)"model":"([^"]+)"')
    if ($matches.Count -gt 0) {
        $lastModel = $matches[$matches.Count - 1].Groups[1].Value
    }
}

# 2. Usage API
$extraWindows = @()
if ($usageApi) {
    $cacheDir = Join-Path (Join-Path $env:USERPROFILE ".cache") "statusline"
    $xdgCache = [Environment]::GetEnvironmentVariable("XDG_CACHE_HOME")
    if ($xdgCache) { $cacheDir = Join-Path $xdgCache "statusline" }
    
    $cacheFile = Join-Path $cacheDir "usage.json"
    $lockDir = Join-Path $cacheDir "refresh.lock"
    $backoffFile = Join-Path $cacheDir "failed-at"
    $credsFile = Join-Path $claudeDir ".credentials.json"
    
    $ttl = 300; $failTtl = 1800; $idle = 900
    
    $busy = $true
    if ($transcriptPath -and (Test-Path $transcriptPath)) {
        $lastWrite = (Get-Item $transcriptPath).LastWriteTimeUtc
        if (([DateTime]::UtcNow - $lastWrite).TotalSeconds -gt $idle) { $busy = $false }
    }
    
    if ($busy -and (Test-Path $credsFile)) {
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
        $stale = $true
        if (Test-Path $cacheFile) {
            if (([DateTime]::UtcNow - (Get-Item $cacheFile).LastWriteTimeUtc).TotalSeconds -le $ttl) { $stale = $false }
        }
        if (Test-Path $backoffFile) {
            if (([DateTime]::UtcNow - (Get-Item $backoffFile).LastWriteTimeUtc).TotalSeconds -le $failTtl) { $stale = $false }
        }
        if (Test-Path $lockDir) {
            if (([DateTime]::UtcNow - (Get-Item $lockDir).LastWriteTimeUtc).TotalSeconds -gt 60) { Remove-Item -Path $lockDir -Force }
        }
        
        if ($stale) {
            try {
                New-Item -ItemType Directory -Path $lockDir -ErrorAction Stop | Out-Null
                # Launch background job
                Start-Job -ScriptBlock {
                    param($credsFile, $cacheFile, $backoffFile, $lockDir)
                    try {
                        $creds = Get-Content $credsFile | ConvertFrom-Json
                        $token = $creds.claudeAiOauth.accessToken
                        if ($token) {
                            $url = "https://api.anthropic.com/api/oauth/usage"
                            $headers = @{ "Authorization" = "Bearer $token"; "anthropic-beta" = "oauth-2025-04-20" }
                            $resp = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 5 -ErrorAction Stop
                            $resp | ConvertTo-Json -Depth 10 | Set-Content $cacheFile
                            if (Test-Path $backoffFile) { Remove-Item $backoffFile }
                        }
                    } catch {
                        New-Item -ItemType File -Path $backoffFile -Force | Out-Null
                    } finally {
                        if (Test-Path $lockDir) { Remove-Item -Path $lockDir -Force -Recurse }
                    }
                } -ArgumentList $credsFile, $cacheFile, $backoffFile, $lockDir | Out-Null
            } catch {}
        }
    }
    
    if (Test-Path $cacheFile) {
        try {
            $cache = Get-Content $cacheFile | ConvertFrom-Json
            if ($cache.limits) {
                foreach ($l in $cache.limits) {
                    if ($l.kind -eq "weekly_scoped" -and $l.scope -is [string]) {
                        $extraWindows += @{ name = $l.scope; used = $l.percent; resets_at = $l.resets_at }
                    }
                }
            }
            if ($cache.seven_day_overage_included -and $null -ne $cache.seven_day_overage_included.utilization) {
                $extraWindows += @{ name = "fable"; used = $cache.seven_day_overage_included.utilization; resets_at = $cache.seven_day_overage_included.resets_at }
            }
        } catch {}
    }
}

# Formatting and Logic
$modelName = if ($inputJson.model.display_name) { $inputJson.model.display_name } else { "" }
$workspaceDir = if ($inputJson.workspace.current_dir) { $inputJson.workspace.current_dir } else { "" }
$ctx = $inputJson.context_window
$rl = $inputJson.rate_limits
$quota = $inputJson.quota

function Get-ColorString($n, $s) { return "$([char]27)[38;5;$($n)m$s$([char]27)[0m" }
function Get-DimString($s) { return Get-ColorString 240 $s }
function Format-Number($t) {
    if ($null -eq $t) { return "0" }
    if ($t -ge 1000000) { return "$([math]::Floor($t / 100000) / 10)M" }
    if ($t -ge 1000) { return "$([math]::Floor($t / 100) / 10)k" }
    return "$t"
}
function Format-Percent($p) { return "$([math]::Floor($p))%" }
function Get-Hue($p) {
    if ($p -ge 90) { return 196 }
    if ($p -ge 70) { return 214 }
    return 108
}
function Format-Clock($s) {
    if ($s -ge 172800) { return "$([math]::Floor($s / 86400))d" }
    if ($s -ge 3600) { return "$([math]::Floor($s / 3600))h$([math]::Floor(($s % 3600) / 60))m" }
    return "$([math]::Floor(($s % 3600) / 60))m"
}
function Format-Resets($at) {
    if (-not $at) { return "" }
    $atTime = [DateTime]::Parse($at).ToUniversalTime()
    $diff = ($atTime - [DateTime]::UtcNow).TotalSeconds
    if ($diff -le 0) { return "" }
    return " " + (Get-DimString "($(Format-Clock $diff))")
}
function Format-Budget($txt, $used, $at) {
    $left = 100 - $used
    return (Get-DimString "$txt ") + (Get-ColorString (Get-Hue $used) "$(Format-Percent $left) left") + (Format-Resets $at)
}
function Format-Usd($v) {
    if ($null -eq $v) { $v = 0 }
    $c = [math]::Round($v * 100)
    $dollars = [math]::Floor($c / 100)
    $cents = $c % 100
    return "`$$dollars.$($cents.ToString('00'))"
}

function Format-PrettyModel($id) {
    $l = $id.ToLower() -replace "\[\(].*$", "" -replace "-v\d+:\d+$", ""
    $fam = @("opus", "sonnet", "haiku", "fable", "gemini") | Where-Object { $l.Contains($_) } | Select-Object -First 1
    if (-not $fam) { return $id }
    
    $verMatch = [regex]::Matches($l, "\d+")
    $ver = @()
    foreach ($m in $verMatch) { if ($m.Value.Length -le 2) { $ver += $m.Value } }
    $verStr = ($ver | Select-Object -First 2) -join "."
    $famCap = $fam.Substring(0,1).ToUpper() + $fam.Substring(1)
    if ($verStr) { return "$famCap $verStr" }
    return $famCap
}

$cleanModel = $modelName -replace " *\([^)]*\)$", ""
if ($lastModel) {
    $prettyLast = Format-PrettyModel $lastModel
    $lastFam = $prettyLast.ToLower().Split(" ")[0]
    $currFam = $cleanModel.ToLower().Split(" ")[0]
    if ($lastFam -ne $currFam) { $cleanModel = $prettyLast }
}

$parts = @()
$parts += Get-ColorString 75 $cleanModel

if ($Mode -eq "full" -and $workspaceDir) {
    $homeDir = $env:USERPROFILE
    $displayDir = $workspaceDir
    if ($displayDir.StartsWith($homeDir)) { $displayDir = "~" + $displayDir.Substring($homeDir.Length) }
    $parts += Get-ColorString 244 $displayDir
}

if ($ctx) {
    $parts += (Get-DimString "ctx ") + (Get-ColorString (Get-Hue $ctx.used_percentage) "$(Format-Number $ctx.total_input_tokens)/$(Format-Number $ctx.context_window_size) $(Format-Percent $ctx.used_percentage)")
}

if ($rl.five_hour) {
    $parts += Format-Budget "5h" $rl.five_hour.used_percentage $rl.five_hour.resets_at
} elseif ($quota."gemini-5h" -and $cleanModel.ToLower().Contains("gemini")) {
    $parts += Format-Budget "5h" ((1 - $quota."gemini-5h".remaining_fraction) * 100) ([DateTime]::UtcNow.AddSeconds($quota."gemini-5h".reset_in_seconds).ToString("o"))
} elseif ($quota."3p-5h") {
    $parts += Format-Budget "5h" ((1 - $quota."3p-5h".remaining_fraction) * 100) ([DateTime]::UtcNow.AddSeconds($quota."3p-5h".reset_in_seconds).ToString("o"))
}

if ($Mode -eq "full") {
    if ($rl.seven_day) {
        $parts += Format-Budget "7d" $rl.seven_day.used_percentage $rl.seven_day.resets_at
    } elseif ($quota."gemini-weekly" -and $cleanModel.ToLower().Contains("gemini")) {
        $parts += Format-Budget "7d" ((1 - $quota."gemini-weekly".remaining_fraction) * 100) ([DateTime]::UtcNow.AddSeconds($quota."gemini-weekly".reset_in_seconds).ToString("o"))
    } elseif ($quota."3p-weekly") {
        $parts += Format-Budget "7d" ((1 - $quota."3p-weekly".remaining_fraction) * 100) ([DateTime]::UtcNow.AddSeconds($quota."3p-weekly".reset_in_seconds).ToString("o"))
    }
}

foreach ($ex in $extraWindows) {
    $parts += Format-Budget $ex.name $ex.used $ex.resets_at
}

if ($rl.spend_limit) {
    $parts += Format-Budget "spend" $rl.spend_limit.used_percentage $rl.spend_limit.resets_at
}

$showCost = $false
if ($costSetting -eq "1") { $showCost = $true }
elseif ($costSetting -eq "0") { $showCost = $false }
else { if (-not $rl.five_hour -and -not $quota) { $showCost = $true } }

if ($showCost -and $inputJson.cost) {
    $parts += Get-DimString (Format-Usd $inputJson.cost.total_cost_usd)
}

$outStr = $parts -join (Get-ColorString 238 " | ")

$extraScript = Join-Path $claudeDir "statusline-extra.ps1"
if (Test-Path $extraScript) {
    try {
        $extraOut = $inputString | powershell -File $extraScript -ErrorAction SilentlyContinue
        if ($extraOut) { $outStr += " " + $extraOut }
    } catch {}
}

Write-Host -NoNewline $outStr
