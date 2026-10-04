#Requires -Version 5.1
<#
.SYNOPSIS
    给 fly.io 上的 frps 追加端口映射（连续端口段）。

.DESCRIPTION
    一次改动两处，保证「外部能访问」且「frps 允许占用」：
      1. fly.toml     ：为每个端口加一个 [[services]] 块（外部端口 = internal_port）
      2. frps.toml    ：把端口段写进 allowPorts 白名单（UDP 则写 frps-udp.toml）
    可选加 -Deploy 直接部署生效。

.EXAMPLE
    ./add-port.ps1 -List
        列出当前已开放的端口映射。

    ./add-port.ps1 -Protocol tcp -StartPort 6005 -Count 5
        新增 TCP 6005-6009（只改文件，不部署）。

    ./add-port.ps1 -Protocol udp -StartPort 6105 -Count 5 -Deploy
        新增 UDP 6105-6109 并立即部署。
#>
[CmdletBinding(DefaultParameterSetName = 'Add')]
param(
    [Parameter(ParameterSetName = 'Add', Mandatory = $true)]
    [ValidateSet('tcp', 'udp', 'http', 'https')]
    [string] $Protocol,

    [Parameter(ParameterSetName = 'Add', Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int] $StartPort,

    [Parameter(ParameterSetName = 'Add')]
    [ValidateRange(1, 500)]
    [int] $Count = 1,

    [Parameter(ParameterSetName = 'Add')]
    [switch] $Deploy,

    [Parameter(ParameterSetName = 'List')]
    [switch] $List
)

$ErrorActionPreference = 'Stop'
$root      = $PSScriptRoot
$flyToml   = Join-Path $root 'fly.toml'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    $m" -ForegroundColor Red }
function Write-Tip  { param($m) Write-Host "    $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
function Get-PortMap {
    $cur = $null
    $result = @()
    foreach ($line in (Get-Content $flyToml)) {
        if ($line -match '^\s*\[\[services\]\]') {
            if ($null -ne $cur) { $result += $cur }
            $cur = [pscustomobject]@{ Protocol = ''; InternalPort = ''; Ports = @() }
        }
        elseif ($null -ne $cur) {
            if ($line -match "^\s*protocol\s*=\s*'([^']+)'")          { $cur.Protocol     = $Matches[1] }
            elseif ($line -match '^\s*internal_port\s*=\s*(\d+)')     { $cur.InternalPort = $Matches[1] }
            elseif ($line -match '^\s*port\s*=\s*(\d+)')              { $cur.Ports       += $Matches[1] }
        }
    }
    if ($null -ne $cur) { $result += $cur }
    return $result
}

# =============================== -List ===============================
if ($List) {
    Write-Step '当前 fly.toml 中的端口映射'
    Get-PortMap | ForEach-Object {
        [pscustomobject]@{
            协议       = $_.Protocol
            容器端口   = $_.InternalPort
            外部端口   = ($_.Ports -join ',')
        }
    } | Format-Table -AutoSize

    Write-Step 'frps 端口白名单'
    foreach ($f in 'frps.toml', 'frps-udp.toml') {
        $p = Join-Path $root $f
        if (Test-Path $p) {
            $t = Get-Content $p -Raw
            $m = [regex]::Match($t, '(?s)allowPorts\s*=\s*\[(.*?)\]')
            Write-Host ("  $f : " + $(if ($m.Success) { (($m.Groups[1].Value -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ') } else { '(未设置，不限制)' }))
        }
    }
    Write-Host ''
    Write-Tip 'HTTP 8080 / HTTPS 8443 是 vhost 端口，不能当 remotePort 用。'
    exit 0
}

# =============================== 新增端口 ===============================
$EndPort = $StartPort + $Count - 1
if ($EndPort -gt 65535) { Write-Err "端口超出范围：$StartPort-$EndPort"; exit 1 }

Write-Step "新增 $Protocol 端口 $StartPort-$EndPort"

# --- 冲突检查 ---
foreach ($reserved in 7000, 7001) {
    if ($StartPort -le $reserved -and $EndPort -ge $reserved) {
        Write-Warn "端口段包含 $reserved（frps 控制端口），会被覆盖！"
    }
}
if ($Protocol -ne 'udp' -and (($StartPort -le 8080 -and $EndPort -ge 8080) -or ($StartPort -le 8443 -and $EndPort -ge 8443))) {
    Write-Warn '端口段包含 8080 / 8443，它们已被 vhostHTTPPort / vhostHTTPSPort 占用，客户端不能用它们做 remotePort。'
}
if ($Protocol -eq 'udp') {
    Write-Tip 'UDP 需要独立 IPv4：fly ips allocate-v4；客户端要连 7001 端口的 frps 实例。'
}

$proto   = $Protocol                 # fly.toml 里只有 tcp / udp 两种
if ($proto -eq 'http' -or $proto -eq 'https') { $proto = 'tcp' }
$frpsFile = if ($Protocol -eq 'udp') { 'frps-udp.toml' } else { 'frps.toml' }
$frpsPath = Join-Path $root $frpsFile

# ---------------------------------------------------------------- 1. fly.toml
Write-Step "写入 $flyToml"
if (-not (Test-Path $flyToml)) { Write-Err "找不到 $flyToml"; exit 1 }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([string[]](Get-Content $flyToml))
$text  = ($lines -join "`n")

$added = @()
$block = [System.Collections.Generic.List[string]]::new()
for ($p = $StartPort; $p -le $EndPort; $p++) {
    if ($text -match "(?m)^\s*port\s*=\s*$p\s*$") {
        Write-Warn "端口 $p 在 fly.toml 里已存在，跳过"
        continue
    }
    $block.Add("[[services]]")
    $block.Add("  protocol = '$proto'")
    $block.Add("  internal_port = $p")
    $block.Add("")
    $block.Add("  [[services.ports]]")
    $block.Add("    port = $p")
    $block.Add("")
    $added += $p
}

if ($added.Count -eq 0) {
    Write-Warn '没有新增任何端口，fly.toml 未改动'
} else {
    $block.Insert(0, "# --- $Protocol 穿透 $($added[0])-$($added[-1])（add-port.ps1 添加）---")
    $block.Insert(1, "")

    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[\[vm\]\]') { $idx = $i; break }
    }
    if ($idx -ge 0) {
        foreach ($l in $block) { $lines.Insert($idx, $l); $idx++ }
    } else {
        foreach ($l in $block) { $lines.Add($l) }
    }
    [System.IO.File]::WriteAllLines($flyToml, $lines)
    Write-Ok ("已添加: " + ($added -join ', '))
}

# ---------------------------------------------------------------- 2. allowPorts
Write-Step "写入 $frpsFile 的 allowPorts"
if (-not (Test-Path $frpsPath)) { Write-Err "找不到 $frpsPath"; exit 1 }

$fLines = [System.Collections.Generic.List[string]]::new()
$fLines.AddRange([string[]](Get-Content $frpsPath))
$open = -1; $close = -1
for ($i = 0; $i -lt $fLines.Count; $i++) {
    if ($open -lt 0) {
        if ($fLines[$i] -match '^\s*allowPorts\s*=\s*\[') { $open = $i }
    } elseif ($fLines[$i] -match '^\s*\]') { $close = $i; break }
}

if ($open -lt 0 -or $close -lt 0) {
    Write-Warn "没在 $frpsFile 里找到 allowPorts 数组，请手动加入：{ start = $StartPort, end = $EndPort },"
} else {
    $dup = $false
    for ($i = $open; $i -le $close; $i++) {
        if ($fLines[$i] -match "start\s*=\s*$StartPort\s*,\s*end\s*=\s*$EndPort") { $dup = $true; break }
    }
    if ($dup) {
        Write-Warn "allowPorts 里已有 $StartPort-$EndPort，未改动"
    } else {
        $fLines.Insert($close, "  { start = $StartPort, end = $EndPort },   # $Protocol 穿透")
        [System.IO.File]::WriteAllLines($frpsPath, $fLines)
        Write-Ok "已加入白名单: $StartPort-$EndPort"
    }
}

# ---------------------------------------------------------------- 3. 部署
Write-Step '完成'

$scheme = ''
if     ($Protocol -eq 'http')  { $scheme = 'http://' }
elseif ($Protocol -eq 'https') { $scheme = 'https://' }

$howto = 'type = "' + $Protocol + '", remotePort = ' + $StartPort
if ($Protocol -eq 'http'  -and $StartPort -eq 8080) { $howto = 'type = "http"  + customDomains（vhost 端口，按域名路由）' }
if ($Protocol -eq 'https' -and $StartPort -eq 8443) { $howto = 'type = "https" + customDomains（vhost 端口，按域名路由）' }
if ($Protocol -eq 'udp') { $howto = $howto + '（frpc 要连 serverPort = 7001 的 UDP 实例）' }

Write-Host ''
Write-Host ("  协议     : " + $Protocol) -ForegroundColor Cyan
Write-Host ("  端口段   : $StartPort-$EndPort") -ForegroundColor Cyan
Write-Host ("  访问方式 : " + $scheme + "你的应用名.fly.dev:" + $StartPort) -ForegroundColor Cyan
Write-Host ("  frpc     : " + $howto) -ForegroundColor Cyan
Write-Host ''

if ($Deploy) {
    Write-Step '部署到 fly.io（fly deploy）'
    Push-Location $root
    try {
        fly deploy
        if ($LASTEXITCODE -ne 0) { Write-Err '部署失败'; exit 1 }
        Write-Ok '部署完成'
    } finally { Pop-Location }
} else {
    Write-Tip '只改了本地文件，执行 ./deploy.ps1 或 fly deploy 后才会生效。'
}
