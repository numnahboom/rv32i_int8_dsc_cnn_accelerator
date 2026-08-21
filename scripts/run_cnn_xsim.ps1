param(
    [string[]]$Tests = @(
        "tb_ds_block_tile_engine_new",
        "tb_feature_sram_bank",
        "tb_cnn_layer_runner_sram_bounds",
        "tb_cnn_top_ctrl_bounds",
        "tb_cnn_top_dsblock_datapath",
        "tb_cnn_top_backpressure",
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

$lockDir = Join-Path $projectRoot "build"
$reportDir = Join-Path $lockDir "reports"
$lockPath = Join-Path $lockDir "cnn_xsim.lock"
New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
try {
    $lockStream = [System.IO.File]::Open(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
} catch {
    throw "Another CNN XSim regression is already using the shared xsim.dir: $lockPath"
}

Push-Location $projectRoot
try {
    if (($Tests.Count -eq 1) -and ($Tests[0] -match ',')) {
        $Tests = @($Tests[0] -split ',' | ForEach-Object { $_.Trim() } |
            Where-Object { $_ })
    }

    if ($Tests -contains "tb_cnn_top_fullnet_sram_datapath") {
        foreach ($artifact in @(
            "tb_cnn_top_fullnet_sram_datapath_metrics.txt",
            "fullnet_layer_metrics.csv",
            "fullnet_hw_logits.hex",
            "fullnet_expected_logits.hex",
            "inference_accuracy_perf.md"
        )) {
            $artifactPath = Join-Path $reportDir $artifact
            if (Test-Path -LiteralPath $artifactPath) {
                Remove-Item -LiteralPath $artifactPath -Force
            }
        }
    }

    $rtlFiles = Get-Content "sim/filelist_cnn_current.f" |
        Where-Object { $_ }
    $tbFiles = $Tests | ForEach-Object {
        $tbPath = "sim/$_.v"
        if (-not (Test-Path -LiteralPath $tbPath)) {
            throw "Unknown or missing testbench: $tbPath"
        }
        $tbPath
    }

    # Compile RTL one source at a time as well.  Vivado 2021.2 can spend tens
    # of minutes in a single multi-file xvlog invocation without updating the
    # work library or identifying the pathological source.  Incremental units
    # retain normal Verilog unresolved-module semantics until elaboration and
    # make both progress and failures reproducible.
    Write-Host "COMPILE cnn_xsim rtl=$($rtlFiles.Count)"
    foreach ($rtlFile in $rtlFiles) {
        $compileWatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Host "COMPILE $rtlFile"
        & $xvlog -sv $rtlFile
        $compileWatch.Stop()
        if ($LASTEXITCODE -ne 0) {
            throw "xvlog RTL compile failed: $rtlFile (exit code $LASTEXITCODE)"
        }
        Write-Host "COMPILED $rtlFile seconds=$([math]::Round($compileWatch.Elapsed.TotalSeconds, 1))"
    }

    # Compile testbenches one at a time.  Vivado 2021.2 can spend tens of
    # minutes without progress output when many large TBs share one xvlog
    # invocation; incremental compilation is both faster to diagnose and
    # identifies the exact source that failed.
    foreach ($tbFile in $tbFiles) {
        Write-Host "COMPILE $tbFile"
        & $xvlog -sv $tbFile
        if ($LASTEXITCODE -ne 0) {
            throw "xvlog testbench compile failed: $tbFile (exit code $LASTEXITCODE)"
        }
    }

    $failed = @()
    foreach ($test in $Tests) {
        $snapshot = "${test}_xsim"
        Write-Host "ELABORATE $test"
        & $xelab $test -s $snapshot
        if ($LASTEXITCODE -ne 0) {
            Write-Host "FAIL $test (elaboration)"
            $failed += $test
            continue
        }

        Write-Host "SIMULATE $test"
        $simOutput = & $xsim $snapshot -runall 2>&1 | Out-String
        $simExitCode = $LASTEXITCODE
        $passPattern = "PASS\s+$([regex]::Escape($test))\b"
        if (($simExitCode -eq 0) -and ($simOutput -match $passPattern)) {
            $passLine = ($simOutput -split "`r?`n" |
                Where-Object { $_ -match $passPattern } |
                Select-Object -Last 1)
            Write-Host $passLine
        } else {
            Write-Host "FAIL $test (xsim exit code $simExitCode)"
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

    if ($Tests -contains "tb_cnn_top_fullnet_sram_datapath") {
        Write-Host "REPORT fullnet accuracy/performance"
        & python "python/inference_accuracy_perf_report.py"
        if ($LASTEXITCODE -ne 0) {
            throw "fullnet report generation failed with exit code $LASTEXITCODE"
        }
    }

    Write-Host "PASS cnn_xsim_regression tests=$($Tests.Count)"
} finally {
    Pop-Location
    $lockStream.Dispose()
}
