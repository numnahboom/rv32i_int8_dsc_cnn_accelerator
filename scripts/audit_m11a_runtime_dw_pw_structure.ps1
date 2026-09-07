$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$top = Join-Path $root 'rtl\cnn\m11a_runtime_dw_pw_core.v'
$dw = Join-Path $root 'rtl\cnn\m11a_dw16_shared_line.v'
$pw = Join-Path $root 'rtl\cnn\m11a_pw64_shared_core.v'
$pack = Join-Path $root 'rtl\cnn\m11a_context_packer.v'
$cfg = Join-Path $root 'rtl\cnn\m11a_runtime_cfg_store.v'
$topText = Get-Content -Raw -LiteralPath $top
$dwText = Get-Content -Raw -LiteralPath $dw
$pwText = Get-Content -Raw -LiteralPath $pw
$packText = Get-Content -Raw -LiteralPath $pack
$cfgText = Get-Content -Raw -LiteralPath $cfg
$dwInst = ([regex]::Matches($topText, 'm11a_dw16_shared_line\s+dw16')).Count
$pwInst = ([regex]::Matches($topText, 'm11a_pw64_shared_core\s+pw64')).Count
$macSites = ([regex]::Matches($pwText, 'for \(gp = 0; gp < 64; gp')).Count
$lineStores = ([regex]::Matches($dwText, 'line[012]_mem')).Count
$rowRam = ([regex]::Matches($cfgText, 'pw_row_mem')).Count
$oldNames = @('ds12_shared_pw_service','ds12_stream_ds1_pw_consumer','ds12_stream_ds2_pw_consumer','cnn_top','cnn_layer_runner') |
    Where-Object { ($topText + $dwText + $pwText + $packText + $cfgText) -match [regex]::Escape($_) }
if ($dwInst -ne 1 -or $pwInst -ne 1 -or $macSites -ne 1 -or $oldNames.Count -ne 0 -or $lineStores -lt 3 -or $rowRam -lt 1) {
    Write-Host "M11A_STRUCTURE_FAIL dw_instances=$dwInst pw_instances=$pwInst mac_generate_sites=$macSites line_store_refs=$lineStores row_ram_refs=$rowRam old=$($oldNames -join ',')"
    exit 1
}
Write-Host "M11A_STRUCTURE_PASS unique_dw16=1 unique_pw64=1 pw_mac_lanes=64 shared_3line=1 pw_row_bram=1 old_consumer_refs=0"
