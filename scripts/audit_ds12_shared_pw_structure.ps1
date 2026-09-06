$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$top = Join-Path $root 'rtl\cnn\ds12_shared_pw_two_layer_top.v'
$service = Join-Path $root 'rtl\cnn\ds12_shared_pw_service.v'
$adapter1 = Join-Path $root 'rtl\cnn\ds12_shared_pw_ds1_adapter.v'
$adapter2 = Join-Path $root 'rtl\cnn\ds12_shared_pw_ds2_adapter.v'
$files = @($top, $service, $adapter1, $adapter2)
$text = ($files | ForEach-Object { Get-Content -Raw -LiteralPath $_ }) -join "`n"
$serviceInstances = ([regex]::Matches((Get-Content -Raw -LiteralPath $top), 'ds12_shared_pw_service\s+service')).Count
$macInstances = ([regex]::Matches((Get-Content -Raw -LiteralPath $service), 'ds12_shared_pw_mac_lane\s+u_mac')).Count
$forbidden = @('ds12_stream_ds1_pw_consumer', 'ds12_stream_ds2_pw_consumer', 'ds12_stream_pure_two_layer_top') |
  Where-Object { $text -match [regex]::Escape($_) }
if ($serviceInstances -ne 1 -or $macInstances -ne 1 -or $forbidden.Count -ne 0) {
  Write-Host "SHARED_STRUCTURE_FAIL service_instances=$serviceInstances mac_generate_sites=$macInstances forbidden=$($forbidden -join ',')"
  exit 1
}
$generateSites = ([regex]::Matches((Get-Content -Raw -LiteralPath $service), 'for \(gp = 0; gp < 8; gp')).Count
Write-Host "SHARED_STRUCTURE_PASS top=$top service_instances=1 mac_generate_sites=$generateSites lanes=64 forbidden_old_pw_consumers=0"
