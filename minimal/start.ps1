param([string]$PortName='', [string]$PythonExecutable='python')
$ErrorActionPreference='Stop'
$taskArguments=@('-B',(Join-Path $PSScriptRoot 'host\start_camera.py'))
if($PortName){$taskArguments+=@('--port',$PortName)}
& $PythonExecutable @taskArguments
if($LASTEXITCODE -ne 0){throw 'Recognition startup failed. Inspect the message and minimal/logs.'}
