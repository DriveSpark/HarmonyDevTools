param([string]$DevEcoHome = $(if ($env:DEVECO_HOME) { $env:DEVECO_HOME } else { 'C:\Program Files\Huawei\DevEco Studio' }))

$ErrorActionPreference = 'Stop'
$node = Join-Path $DevEcoHome 'tools/node/node.exe'
$hvigor = Join-Path $DevEcoHome 'tools/hvigor/bin/hvigorw.js'
$ohpm = Join-Path $DevEcoHome 'tools/ohpm/bin/ohpm.bat'
$previous = @{}
Push-Location -LiteralPath $PSScriptRoot
try {
  foreach ($name in 'DEVECO_HOME', 'DEVECO_SDK_HOME', 'JAVA_HOME', 'NODE_HOME', 'Path') {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
  }
  $env:DEVECO_HOME = $DevEcoHome
  $env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
  $env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
  $env:NODE_HOME = Join-Path $DevEcoHome 'tools/node'
  $env:Path = "$env:NODE_HOME;$env:JAVA_HOME\bin;$env:Path"

  & $ohpm install --all
  if ($LASTEXITCODE -ne 0) { throw "ohpm install failed ($LASTEXITCODE)" }
  & $node $hvigor --mode module -p product=default -p module=devtools@default -p buildMode=release assembleHar --no-daemon
  if ($LASTEXITCODE -ne 0) { throw "assembleHar failed ($LASTEXITCODE)" }

  $packages = @(Get-ChildItem -LiteralPath 'devtools/build/default/outputs/default' -Filter '*.har' -File)
  if ($packages.Count -ne 1) { throw 'Expected exactly one release HAR' }
  $har = $packages[0].FullName
  $members = @(& tar.exe -tf $har)
  if ($LASTEXITCODE -ne 0 -or !($members -match '/modules\.abc$')) { throw 'Missing ArkTS bytecode' }
  $required = @('README.md', 'LICENSE', 'CHANGELOG.md', 'libs/arm64-v8a/libdevtools_hilog.so',
    'libs/x86_64/libdevtools_hilog.so', 'src/main/cpp/types/libdevtools_hilog/oh-package.json5',
    'src/main/cpp/types/libdevtools_hilog/Index.d.ts', 'src/main/resources/rawfile/devtools_artwork.txt',
    'src/main/resources/rawfile/devtools_dokit_license.txt')
  foreach ($part in $required) {
    if ("package/$part" -notin $members) { throw "HAR is missing $part" }
  }
  foreach ($asset in 'devtools_align_ruler.png', 'devtools_launcher_hammer.svg', 'devtools_device_info.svg', 'devtools_screen_info.svg') {
    if (!($members -like "*/media/$asset")) { throw "HAR is missing $asset" }
  }
  $source = Get-Content -LiteralPath 'devtools/oh-package.json5' -Raw | ConvertFrom-Json
  $manifest = (& tar.exe -xOf $har package/oh-package.json5 | Out-String) | ConvertFrom-Json
  $module = (& tar.exe -xOf $har package/src/main/module.json | Out-String) | ConvertFrom-Json
  if ($manifest.name -ne 'com.ttxz.devtools' -or $manifest.version -ne $source.version -or
      $manifest.author -ne $source.author -or $manifest.license -ne 'Apache-2.0' -or
      $module.app.bundleName -ne $manifest.name -or $module.app.buildMode -ne 'release' -or
      $manifest.compatibleSdkVersion -ne 20 -or $manifest.metadata.byteCodeHar -ne $true) {
    throw 'Unexpected release package identity, format or compatibility'
  }
  $deps = @($manifest.dependencies.PSObject.Properties | Where-Object { $_.Name })
  foreach ($dep in $deps) {
    if ($dep.Name -ne 'libdevtools_hilog.so' -or $dep.Value -notmatch '^file:(\./)?src/main/cpp/types/libdevtools_hilog/?$') {
      throw "Unexpected package dependency: $($dep.Name)"
    }
  }
  if (($manifest.metadata.dependencyPkgVersion.PSObject.Properties | Where-Object { $_.Name -and $_.Name -ne 'libdevtools_hilog.so' }) -or
      $module.module.dependencies) { throw 'Unexpected external module dependency' }

  $outDir = [IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'build/outputs/release')).FullName
  $out = Join-Path $outDir ('{0}-{1}.har' -f $manifest.name, $manifest.version)
  Copy-Item -LiteralPath $har -Destination $out -Force
  Write-Output $out
} finally {
  Pop-Location
  foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
