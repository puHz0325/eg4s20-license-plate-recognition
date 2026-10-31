param([string]$ModelSimBin='E:\modelsim\win64',[switch]$UnitOnly,[int[]]$Cases=@(0,1,2))
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$teacher=Join-Path $repoRoot 'car_test/PL/lpr8'
$runDir=Join-Path $repoRoot 'tmp/modelsim_teacher'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$library=(Join-Path $runDir 'work').Replace('\','/')
$vlib=Join-Path $ModelSimBin 'vlib.exe'
$vlog=Join-Path $ModelSimBin 'vlog.exe'
$vsim=Join-Path $ModelSimBin 'vsim.exe'
foreach($exe in @($vlib,$vlog,$vsim)) { if(-not(Test-Path -LiteralPath $exe)) { throw "Missing executable $exe" } }
$sources=@(Get-ChildItem -LiteralPath (Join-Path $teacher 'rtl') -Filter '*.v' | ForEach-Object FullName)
$sources+=Join-Path $repoRoot 'car_test/PL/src/cnn/requantize.v'
$sources+=Join-Path $PSScriptRoot 'lpr8_memory_model.sv'
$benches=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*_tb.sv' | ForEach-Object FullName)
Push-Location $repoRoot
try {
    & python -B (Join-Path $PSScriptRoot 'verify_results.py') --logs $runDir --snapshot
    if($LASTEXITCODE -ne 0) { throw 'Teacher input snapshot failed' }
    if(-not(Test-Path -LiteralPath $library)) {
        & $vlib $library
        if($LASTEXITCODE -ne 0) { throw 'vlib failed' }
    }
    & $vlog -sv -work $library ('+incdir+'+(Join-Path $teacher 'data')) @sources @benches
    if($LASTEXITCODE -ne 0) { throw 'Teacher RTL compile failed' }
    $tests=@(@{Top='teacher_arithmetic_tb';Suffix='arithmetic';Args=@()},@{Top='teacher_ctc_tb';Suffix='ctc';Args=@()})
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lpr8_dma_tb.sv')) { $tests+=@{Top='teacher_dma_tb';Suffix='dma';Args=@()} }
    if(-not $UnitOnly) {
        foreach($case in $Cases) {
            $caseArgs=@('+CASE='+$case)
            if($case -eq 2) { $caseArgs+='+EXTRA_LATENCY=17' }
            $tests+=@{Top='teacher_inference_tb';Suffix=('inference_'+$case);Args=$caseArgs}
        }
    }
    foreach($test in $tests) {
        $log=Join-Path $runDir ($test.Suffix+'.log')
        $simArgs=@('-c','-onfinish','exit','-lib',$library,'-l',$log,'-wlf',(Join-Path $runDir ($test.Suffix+'.wlf')),$test.Top)
        $simArgs+=$test.Args
        $simArgs+=@('-do',('do {'+((Join-Path $PSScriptRoot 'run_batch.do').Replace('\','/'))+'}'))
        & $vsim @simArgs
        $status=$LASTEXITCODE
        $transcript=Get-Content -LiteralPath $log -Raw
        if($status -ne 0 -or $transcript -match '\*\* (Error|Fatal)' -or $transcript -notmatch '# PASS teacher_') {
            throw ('Teacher test failed: '+$test.Suffix+'. See '+$log)
        }
    }
    if(-not $UnitOnly -and @($Cases | Sort-Object -Unique).Count -eq 3 -and ($Cases -contains 0) -and ($Cases -contains 1) -and ($Cases -contains 2)) {
        & python -B (Join-Path $PSScriptRoot 'verify_results.py') --logs $runDir
        if($LASTEXITCODE -ne 0) { throw 'Teacher result verification failed' }
    }
    Write-Output ('PASS teacher RTL suite. Logs: '+$runDir)
} finally { Pop-Location }
