$ErrorActionPreference = 'Stop'
$scriptUnderTest = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Wait-CommandOutput.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..\work') ('test-' + [guid]::NewGuid().ToString('N'))))
$null = [IO.Directory]::CreateDirectory($root)
$passed = [Collections.Generic.List[string]]::new()
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Invoke-Subject([hashtable]$arguments, [int]$expectedCode) {
    $arguments['Verbose'] = $true
    $json = & $scriptUnderTest @arguments
    Assert ($LASTEXITCODE -eq $expectedCode) "Exit $LASTEXITCODE != $expectedCode. Output: $json"
    return $json | ConvertFrom-Json
}
function Start-TestJob([string]$name, [string]$source, [string]$pattern = 'READY', [hashtable]$extra = @{}) {
    $arguments = @{ Mode='Start'; Command=$source; Pattern=$pattern; JobPath=(Join-Path $root $name) }
    foreach ($key in $extra.Keys) { $arguments[$key] = $extra[$key] }
    return Invoke-Subject $arguments 0
}
function Start-Waiter([string]$path) {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($arg in @('-NoProfile','-NonInteractive','-File',$scriptUnderTest,'-Mode','Wait','-JobPath',$path,'-TimeoutSeconds','15','-Verbose')) { $info.ArgumentList.Add($arg) }
    return [Diagnostics.Process]::Start($info)
}
function Finish-Waiter($process, [int]$expectedCode) {
    $output = $process.StandardOutput.ReadToEndAsync()
    $errorOutput = $process.StandardError.ReadToEndAsync()
    Assert ($process.WaitForExit(20000)) 'Waiter failed to terminate.'
    Assert ($process.ExitCode -eq $expectedCode) "Waiter exit=$($process.ExitCode): $($errorOutput.GetAwaiter().GetResult()) $($output.GetAwaiter().GetResult())"
    $result = $output.GetAwaiter().GetResult() | ConvertFrom-Json
    $process.Dispose()
    return $result
}
try {
    $help = Get-Help $scriptUnderTest -Full
    Assert ($help.Description.Text -match 'background_terminal_max_timeout') 'Built-in timeout help missing.'
    Assert ($help.Examples.Example.Count -eq 5) 'Built-in examples missing.'
    $passed.Add('Get-Help exposes instructions and examples')

    $result = Invoke-Subject @{
        Command = '[Console]::Write("检查点"); [Console]::Out.Flush(); Start-Sleep -Milliseconds 250; [Console]::Write("已保存"); [Console]::Out.Flush(); Start-Sleep -Seconds 2; [Console]::Write("TAIL")'
        Pattern = '检查点已保存'; Literal=$true; JobPath=(Join-Path $root 'fragment'); TimeoutSeconds=10
    } 0
    Assert ($result.State -eq 'Matched' -and $null -eq $result.Completion) 'Fragment match did not return before producer exit.'
    $null = Invoke-Subject @{Mode='Wait';JobPath=$result.JobPath;WaitFor='Exit';TimeoutSeconds=10} 0
    Assert ([IO.File]::ReadAllText((Join-Path $result.JobPath 'stdout.log')) -eq '检查点已保存TAIL') 'Supervisor did not keep draining after match.'
    $passed.Add('Unicode, fragmented output without newline, continued training and final drain')

    $job = Start-TestJob 'stderr' '[Console]::Error.Write("epoch 1`rREA"); [Console]::Error.Flush(); Start-Sleep -Milliseconds 200; [Console]::Error.Write("DY")' 'READY' @{Literal=$true;Stream='Stderr'}
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=10} 0
    Assert ($result.Match.Stream -eq 'Stderr') 'Stderr selection failed.'
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;WaitFor='Exit';TimeoutSeconds=10} 0
    $late = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=0} 0
    Assert ($late.Match.Text -eq 'READY') 'Late waiter missed persisted match.'
    $passed.Add('Stderr/carriage returns and reconnect after supervisor exit')

    $job = Start-TestJob 'filtered' '[Console]::Error.Write("READY")' 'READY' @{Literal=$true;Stream='Stdout'}
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=10} 2
    Assert ($result.State -eq 'NoMatch') 'Filtering / no-match termination failed.'
    $passed.Add('Stream filtering and NoMatch exit code')

    $job = Start-TestJob 'failure' 'throw "training failed"'
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=10} 1
    Assert ($result.State -eq 'CommandFailed' -and $result.Completion.ExitCode -eq 1 -and $result.OriginalExitCode -eq 1) 'Command failure was masked.'
    $passed.Add('Terminating PowerShell error propagation')

    $job = Start-TestJob 'nonzero' '[Console]::Write("READY"); exit 17' 'READY' @{Literal=$true}
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=10} 0
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;WaitFor='Exit';TimeoutSeconds=10} 17
    Assert ($result.Completion.ExitCode -eq 17 -and $result.OriginalExitCode -eq 17) 'Failed exit after match was hidden.'
    $passed.Add('Milestone success is independent of later nonzero exit')

    $job = Start-TestJob 'timeout' 'Start-Sleep -Seconds 3; [Console]::Write("READY")' 'READY' @{Literal=$true}
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=1} 3
    Assert ($result.State -eq 'Timeout') 'Wait deadline did not fire.'
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=0} 0
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;WaitFor='Exit';TimeoutSeconds=10} 0
    $passed.Add('Silent timeout leaves producer alive; infinite reconnect succeeds')

    $job = Start-TestJob 'concurrent' 'Start-Sleep -Seconds 4; [Console]::Write("READY"); Start-Sleep -Seconds 1' 'READY' @{Literal=$true}
    $first = Start-Waiter $job.JobPath
    $second = Start-Waiter $job.JobPath
    $one = Finish-Waiter $first 0
    $two = Finish-Waiter $second 0
    Assert ($one.Match.TimestampUtc -eq $two.Match.TimestampUtc) 'Waiters saw different match records.'
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;WaitFor='Exit';TimeoutSeconds=10} 0
    $passed.Add('Two simultaneous event waiters see the same match')

    $job = Start-TestJob 'flood' '$chunk = "x" * 4096; for ($i=0; $i -lt 128; $i++) { [Console]::Out.Write($chunk); [Console]::Error.Write($chunk) }; [Console]::Out.Write("READY")' 'READY' @{Literal=$true;MaxBufferChars=4096}
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=15} 0
    $null = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;WaitFor='Exit';TimeoutSeconds=15} 0
    Assert ((Get-Item (Join-Path $job.JobPath 'stdout.log')).Length -eq (128*4096+5)) 'Stdout flood lost bytes.'
    Assert ((Get-Item (Join-Path $job.JobPath 'stderr.log')).Length -eq (128*4096)) 'Stderr flood lost bytes.'
    $passed.Add('Concurrent pipe draining captures 1 MiB with a bounded 4096-character window')

    $job = Start-TestJob 'regex-fault' '[Console]::Write(("a" * 200) + "!"); [Console]::Out.Flush(); Start-Sleep -Seconds 30' '(a+)+$' @{RegexTimeoutMilliseconds=5}
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=10} 5
    Assert ($result.State -eq 'MonitorFailed' -and $result.Completion.Failure.ExceptionType -match 'RegexMatchTimeout' -and $result.Completion.Failure.HResult -ne 0) 'Regex timeout did not preserve failure diagnostics.'
    $passed.Add('Regex timeout wakes monitor even while the other pipe is silent')

    $job = Start-TestJob 'crash' 'Start-Sleep -Seconds 30' 'READY' @{Literal=$true}
    $waiter = Start-Waiter $job.JobPath
    Start-Sleep -Seconds 2
    $identity = Get-Content -LiteralPath (Join-Path $job.JobPath 'supervisor.json') -Raw | ConvertFrom-Json
    $owned = [Diagnostics.Process]::GetProcessById($identity.Pid)
    Assert ($owned.StartTime.ToUniversalTime().Ticks -eq $identity.StartTicksUtc) 'Unexpected process identity in crash test.'
    $owned.Kill($true)
    $owned.Dispose()
    $result = Finish-Waiter $waiter 5
    Assert ($result.State -eq 'SupervisorLost') 'Supervisor death did not wake live waiter.'
    $passed.Add('Supervisor death wakes an already blocked waiter')

    $result = Invoke-Subject @{Mode='Start';Command='"READY"';Pattern='[';JobPath=(Join-Path $root 'invalid')} 64
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'invalid'))) 'Invalid regex launched work.'
    Assert ($result.Failure.ExceptionType -match 'RegexParseException' -and $result.Failure.HResult -ne 0) 'Setup failure diagnostics were lost.'
    $passed.Add('Invalid regex is rejected before launching a command')

    $job = Start-TestJob 'native-code' '& $PSHOME\pwsh.exe -NoProfile -NonInteractive -Command "exit 23"'
    $result = Invoke-Subject @{Mode='Wait';JobPath=$job.JobPath;TimeoutSeconds=10} 23
    Assert ($result.OriginalExitCode -eq 23 -and $result.State -eq 'CommandFailed') 'Original native failure code changed.'
    $passed.Add('Original native exit code is exposed in JSON and returned unchanged')

    $smallJson = & $scriptUnderTest -Mode Wait -JobPath $job.JobPath -TimeoutSeconds 0
    $small = $smallJson | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 23 -and $small.OriginalExitCode -eq 23) 'Compact output lost original exit code.'
    Assert ($small.PSObject.Properties.Name -notcontains 'Completion') 'Compact output includes full completion.'
    Assert ($smallJson.Length -lt 350) 'Default output is too large.'
    $snapshot = & $scriptUnderTest -Mode Status -JobPath $job.JobPath | ConvertFrom-Json
    Assert ($snapshot.Terminal -and -not $snapshot.MatchSeen) 'Compact status is unclear.'
    $passed.Add('Compact default output and opt-in bounded verbose JSON')

    $passed | ForEach-Object { "PASS: $_" }
    "TOTAL: $($passed.Count) integration checks"
} finally {
    # These processes belong to this test run. Verify identity before cleanup.
    Get-ChildItem -LiteralPath $root -Filter supervisor.json -Recurse | ForEach-Object {
        $id = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        try {
            $owned = [Diagnostics.Process]::GetProcessById($id.Pid)
            if ($owned.StartTime.ToUniversalTime().Ticks -eq $id.StartTicksUtc -and -not $owned.HasExited) { $owned.Kill($true) }
            $owned.Dispose()
        } catch { }
    }
}
