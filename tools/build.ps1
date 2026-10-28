param([string]$Out)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

$propRaw = Get-Content (Join-Path $root "module.prop") -Raw
$ver = [regex]::Match($propRaw, "version=(\S+)").Groups[1].Value
$vcode = [int][regex]::Match($propRaw, "versionCode=(\d+)").Groups[1].Value

# update.json：KSU / Magisk 管理器按 module.prop 的 updateJson 拉它判断更新。
# zipUrl 指向 GitHub Release 资产，changelog 指向该版本的 Release 页。
# 发布时连同 update.json 一起提交，@main 分支的 CDN 才能拿到新版本号。
$update = [ordered]@{
    version     = $ver
    versionCode = $vcode
    zipUrl      = "https://github.com/ManPan-Y/REDMAGIC/releases/download/$ver/REDMAGIC-$ver.zip"
    changelog   = "https://github.com/ManPan-Y/REDMAGIC/releases/tag/$ver"
}
# 手写 JSON 而不是 ConvertTo-Json：后者会输出 4 空格缩进和双空格的冒号，diff 难看
$json = @"
{
  "version": "$($update.version)",
  "versionCode": $($update.versionCode),
  "zipUrl": "$($update.zipUrl)",
  "changelog": "$($update.changelog)"
}
"@
$json = $json -replace "`r`n", "`n"
[IO.File]::WriteAllText((Join-Path $root "update.json"), $json, (New-Object System.Text.UTF8Encoding($false)))

# 先生成 update.json 再自检：check.ps1 会核对它与 module.prop 是否同版本
& (Join-Path $PSScriptRoot "check.ps1")
if ($LASTEXITCODE -ne 0) { throw "check failed, zip not built" }

$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (-not $Out) { $Out = Join-Path $dist "REDMAGIC-$ver.zip" }
# Delete via .NET: no Remove-Item prompts/hooks, no recycle bin.
if ([IO.File]::Exists($Out)) { [IO.File]::Delete($Out) }

$tmp = Join-Path $dist ("build-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    # 只装运行时需要的文件：打包脚本、说明、开发工具都不进 ZIP
    $skip = @("dist", ".git", ".gitattributes", "conf", ".screenshots", ".trae-html-share-packages", "README.md", "CHANGELOG.md", "FILES.md", "tools", "update.json")
    Get-ChildItem $root -Force | Where-Object { $skip -notcontains $_.Name } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $tmp -Recurse -Force
    }

    # Compress-Archive on Windows writes backslash separators; Android unzip then
    # creates files literally named "lib\charge.sh" instead of directories.
    # Write the archive ourselves so every entry uses the ZIP-required "/".
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Out, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $base = $tmp.TrimEnd("\") + "\"
        Get-ChildItem -LiteralPath $tmp -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($base.Length).Replace("\", "/")
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $_.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        $zip.Dispose()
    }

    $zip = [IO.Compression.ZipFile]::OpenRead($Out)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $bad = @($names | Where-Object { $_ -match '\\' })
        if ($bad.Count -gt 0) { throw "ZIP has backslash paths: $($bad[0])" }
        foreach ($req in "module.prop", "customize.sh", "service.sh", "webroot/index.html", "lib/charge.sh") {
            if ($names -notcontains $req) { throw "ZIP missing $req" }
        }
    } finally {
        $zip.Dispose()
    }
    Write-Host "[ OK ] zip layout" -ForegroundColor Green
} finally {
    # Always drop the staging dir, so dist/ never keeps build leftovers.
    if ([IO.Directory]::Exists($tmp)) { [IO.Directory]::Delete($tmp, $true) }
}

Write-Host "output: $Out" -ForegroundColor Green
