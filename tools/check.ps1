param(
    [string]$Adb = "C:\Program Files (x86)\platform-tools\adb.exe",
    [switch]$SkipDevice
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$fail = 0

function Fail($msg) { Write-Host "[FAIL] $msg" -ForegroundColor Red; $script:fail++ }
function Ok($msg) { Write-Host "[ OK ] $msg" -ForegroundColor Green }

# 1) JS syntax
Get-ChildItem (Join-Path $root "webroot\js") -Filter *.js | ForEach-Object {
    node --check $_.FullName
    if ($LASTEXITCODE -ne 0) { Fail "node --check $($_.Name)" } else { Ok "js $($_.Name)" }
}

# 2) CRLF
Get-ChildItem $root -Recurse -File | Where-Object {
    $_.Extension -in ".sh", ".txt", ".js", ".html", ".css", ".prop", ".req", ".md", ".ps1"
} | ForEach-Object {
    $b = [IO.File]::ReadAllBytes($_.FullName)
    for ($i = 0; $i -lt $b.Length - 1; $i++) {
        if ($b[$i] -eq 13 -and $b[$i + 1] -eq 10) { Fail "CRLF: $($_.FullName)"; break }
    }
}

# 3) Contract checks
$status = Get-Content (Join-Path $root "lib\status.sh") -Raw
$touch = Get-Content (Join-Path $root "lib\touch.sh") -Raw
if ($status -match '(?m)^touch_key\(\)') { Fail "status.sh redefines touch_key" } else { Ok "touch_key single definition" }
if ($status -match '(?m)^touch_vals_string\(\)') { Fail "status.sh redefines touch_vals_string" } else { Ok "touch_vals_string single definition" }
if ($touch -match 'rd "\$TP_DIR/edge_report_limit"') { Fail "touch.sh still reads edge_report_limit with 64-byte rd" } else { Ok "edge_report_limit full read" }

# 3.1) 界面不做特效；日志只有一份，不再有 .prev / .last_error
$css = Get-Content (Join-Path $root "webroot\css\style.css") -Raw
if ($css -match '(?m)(^|;|\s)(transition|animation)\s*:' -or $css -match 'linear-gradient|radial-gradient|box-shadow|@keyframes') {
    Fail "style.css 仍有渐变/阴影/过渡/动效"
} else { Ok "css flat (no fx)" }
$pathsSh = Get-Content (Join-Path $root "paths.sh") -Raw
$commonSh = Get-Content (Join-Path $root "common.sh") -Raw
if ($pathsSh -match 'LOG_PREV|ERRLOG') { Fail "paths.sh 还在定义 .prev / .last_error" } else { Ok "single log path" }
if ($commonSh -match 'mlog_rotate') { Fail "common.sh 还在做日志轮转" } else { Ok "log overwrite only" }
# 采样率必须写硬件档位；settings 只允许作为「显示值同步」，且必须走 RATE_SETTING_MAX 常量
$system = Get-Content (Join-Path $root "lib\system.sh") -Raw
if ($system -notmatch '\$TOUCH_REPORT') {
    Fail "采样率没有写驱动节点 tp_report_rate"
} elseif ($system -notmatch 'RATE_SETTING_MAX') {
    Fail "settings 显示同步缺少 RATE_SETTING_MAX 常量"
} else {
    Ok "rate driver + settings mirror"
}
# 升级安装不能整目录删 run/：那里是用户记忆与还原基线
$cust = Get-Content (Join-Path $root "customize.sh") -Raw
if ($cust -match 'rm -rf\s+"\$MODDIR/run"') { Fail "customize.sh 会删除 run/ 用户记忆" } else { Ok "customize keeps run/" }

# 运行期文件必须全部落在 run/ 下，模块根目录只留代码/配置/前端
if ($pathsSh -notmatch '\$RUN_DIR') { Fail "paths.sh 没有 run/ 运行期目录" }
$rootPaths = @([regex]::Matches($pathsSh, '(?m)^[A-Za-z_]\w*="\$MODDIR/([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -notmatch '^(config\.txt|lib/|conf/|run$)' })
if ($rootPaths.Count -gt 0) { Fail "运行期文件散在根目录: $($rootPaths -join ', ')" } else { Ok "runtime under run/" }

$prop = Get-Content (Join-Path $root "module.prop") -Raw
$ver = [regex]::Match($prop, "version=(\S+)").Groups[1].Value
$vtxt = (Get-Content (Join-Path $root "webroot\version.txt") -Raw).Trim()
if ($ver -ne $vtxt) { Fail "version mismatch: $ver / $vtxt" } else { Ok "version $ver" }

# update.json 与 module.prop 必须同版本，且 zipUrl 指向该版本的 Release 资产
$vcode = [regex]::Match($prop, "versionCode=(\d+)").Groups[1].Value
$updPath = Join-Path $root "update.json"
if ($prop -notmatch '(?m)^updateJson=https://') {
    Fail "module.prop 缺少 updateJson"
} elseif (-not (Test-Path $updPath)) {
    Fail "缺少 update.json"
} else {
    $upd = Get-Content $updPath -Raw | ConvertFrom-Json
    if ($upd.version -ne $ver) { Fail "update.json version 不一致: $($upd.version) / $ver" }
    elseif ("$($upd.versionCode)" -ne $vcode) { Fail "update.json versionCode 不一致: $($upd.versionCode) / $vcode" }
    elseif ($upd.zipUrl -notmatch "/download/$ver/REDMAGIC-$ver\.zip$") { Fail "update.json zipUrl 不是当前版本资产" }
    else { Ok "update.json $ver ($vcode)" }
}
if (Test-Path (Join-Path $root "install.sh")) {
    Fail "install.sh is reserved by KernelSU and would bypass customize.sh"
} else {
    Ok "no legacy install.sh"
}

# 4) Android sh syntax (needs a connected device)
if (-not $SkipDevice -and (Test-Path $Adb)) {
    # adb 未连设备时会把错误写到 stderr，Stop 模式下会直接抛异常中断自检
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $dev = & $Adb get-state 2>$null
    $ErrorActionPreference = $eap
    if ($dev -eq "device") {
        Get-ChildItem $root -Recurse -Filter *.sh | ForEach-Object {
            $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))
            $r = & $Adb shell "echo $b64 | base64 -d | sh -n" 2>&1
            if ($LASTEXITCODE -ne 0) { Fail "sh -n $($_.Name): $r" } else { Ok "sh $($_.Name)" }
        }
    } else { Write-Host "[SKIP] no device, sh -n skipped" -ForegroundColor Yellow }
}

if ($fail -gt 0) { Write-Host "`n$fail failed" -ForegroundColor Red; exit 1 }
Write-Host "`nall checks passed" -ForegroundColor Green
# 显式 0：无设备时 adb get-state 的退出码会残留到 $LASTEXITCODE，让 build.ps1 误判
exit 0
