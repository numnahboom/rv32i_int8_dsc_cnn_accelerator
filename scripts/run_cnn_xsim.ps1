param(
    [string[]]$Tests = @(
        "tb_ds_block_tile_engine_new",
        "tb_feature_sram_bank",
        "tb_cnn_top_dsblock_datapath",
        "tb_cnn_top_tiled_stem_datapath",
        "tb_cnn_top_tiled_dsblock_datapath",
        "tb_cnn_top_sram_tiled_dsblock_datapath",
        "tb_cnn_top_ops_datapath",
        "tb_cnn_top_multilayer_datapath",
        "tb_cnn_top_sram_gap_fc_datapath",
        "tb_cnn_top_sram_stem_dsblock_datapath",
        "tb_cnn_top_tail_sram_datapath",
        "tb_cnn_top_e2e_sram_datapath",
        "tb_cnn_top_fullnet_sram_datapath"
    ),
    [string]$VivadoBin = "D:\Software\Xilinx\Vivado\2021.2\bin"
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$xvlog = Join-Path $VivadoBin "xvlog.bat"
$xelab = Join-Path $VivadoBin "xelab.bat"
$xsim = Join-Path $VivadoBin "xsim.bat"

foreach ($tool in @($xvlog, $xelab, $xsim)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        throw "Vivado simulator tool not found: $tool"
    }
}

Push-Location $projectRoot
try {
    $rtlFiles = Get-Content "sim/filelist.f" |
        Where-Object { $_ -and ($_ -notmatch '^rtl/npc/') }
    $tbFiles = $Tests | ForEach-Object {
        $tbPath = "sim/$_.v"
        if (-not (Test-Path -LiteralPath $tbPath)) {
            throw "Unknown or missing testbench: $tbPath"
        }
        $tbPath
    }

    & $xvlog -sv @rtlFiles @tbFiles
    if ($LASTEXITCODE -ne 0) {
        throw "xvlog failed with exit code $LASTEXITCODE"
    }

    $failed = @()
    foreach ($test in $Tests) {
        $snapshot = "${test}_xsim"
        & $xelab $test -s $snapshot
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL $test (elaboration)"
            $failed += $test
            continue
        }

        $simOutput = & $xsim $snapshot -runall 2>&1 | Out-String
        $passPattern = "PASS\s+$([regex]::Escape($test))\b"
        if ($simOutput -match $passPattern) {
            $passLine = ($simOutput -split "`r?`n" |
                Where-Object { $_ -match $passPattern } |
                Select-Object -Last 1)
            Write-Host $passLine
        } else {
            Write-Host "FAIL $test"
            $simOutput -split "`r?`n" |
                Where-Object { $_ -match 'FAIL|MISMATCH|Fatal|timeout|ERROR' } |
                Select-Object -Last 20 |
                ForEach-Object { Write-Host $_ }
            $failed += $test
        }
    }

    if ($failed.Count -ne 0) {
        throw "XSim regression failed: $($failed -join ', ')"
    }

    Write-Host "PASS cnn_xsim_regression tests=$($Tests.Count)"
} finally {
    Pop-Location
}
