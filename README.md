# Codex Wait Command Output

A self-contained PowerShell script that waits for a command's output using a Windows event, without repeatedly reading its logs. Useful for training runs, builds, and other long-running commands driven by an agent.

The script launches a hidden supervisor, drains stdout and stderr concurrently, records the first matching output, and wakes the waiter. Training keeps running after a match. Waiters can reconnect using the saved job directory.

**Requirements:** Windows, PowerShell 7.2 or later, and the same Windows logon session for supervisor and waiter. No PowerShell modules or external services are required.

## Quick start

Run from PowerShell 7 in your training project's directory. Replace the script path with your checkout's absolute path:

```powershell
& 'C:\tools\codex-wait-command-output\Wait-CommandOutput.ps1' `
    -Command 'python -u train.py' `
    -Pattern 'checkpoint saved' -Literal -TimeoutSeconds 0
```

`-TimeoutSeconds 0` disables the wait deadline. Use `3600` for a one-hour deadline; the default is 600 seconds. A deadline stops the waiter only, leaving training running.

The producer must flush its output. Use `python -u` for Python. Matches can span incoming chunks and do not require a newline. `Write-Progress` is not captured text; emit a text milestone instead.

The complete instructions are also embedded in the script:

```powershell
Get-Help 'C:\tools\codex-wait-command-output\Wait-CommandOutput.ps1' -Full
```

## Start once and reconnect

Separate launching the producer from waiting when you want to save the job path before a long wait:

```powershell
$waitScript = 'C:\tools\codex-wait-command-output\Wait-CommandOutput.ps1'

$job = & $waitScript -Mode Start `
    -Command '& .\train.ps1 -Epochs 100' `
    -Pattern 'checkpoint saved' -Literal | ConvertFrom-Json

# Save $job.JobPath. Reuse it if a waiter or agent session is interrupted.
& $waitScript -Mode Wait -JobPath $job.JobPath -TimeoutSeconds 0

# A match is a milestone; separately wait for the command's final exit.
& $waitScript -Mode Wait -JobPath $job.JobPath `
    -WaitFor Exit -TimeoutSeconds 0
```

You can also choose an explicit, **new** `-JobPath` with `Start` or `Run`. Existing job directories are rejected to prevent accidental reuse. Reconnecting with `Wait` never relaunches the producer. The default job directory is `.wait-command-output/<GUID>` under the caller's current directory.

`Run` starts and waits, `Start` starts and returns, `Wait` reconnects, and `Status` reads one snapshot. `Worker` is an internal mode.

## Concise output and original failures

Default output is one compact JSON object. The producer's full logs stay on disk. A typical milestone result is:

```json
{"State":"Matched","JobPath":"C:\runs\example","Stream":"Stdout","Text":"checkpoint saved"}
```

Use native `-Verbose` for expanded but bounded JSON. Neither mode streams the training log into agent context.

```powershell
& $waitScript -Mode Wait -JobPath $job.JobPath -TimeoutSeconds 0 -Verbose
& $waitScript -Mode Status -JobPath $job.JobPath
```

On `CommandFailed`, the script returns the **original child process exit code unchanged**, also exposed as `OriginalExitCode` in JSON. Setup and monitor failures preserve exception type, HRESULT, and native OS error code where available. Detailed failure records remain in the job directory.

| Result | Script exit code |
| --- | --- |
| Started, Snapshot, Matched, or successful Completed | 0 |
| NoMatch: command exited successfully without the requested match | 2 |
| Timeout: wait deadline elapsed; producer was not stopped | 3 |
| CommandFailed | Original command exit code |
| MonitorFailed or SupervisorLost | 5 |
| Invocation/setup Error | 64 |

Original command codes may overlap helper codes. Inspect JSON `State` to distinguish them. A terminating PowerShell exception has no intrinsic process exit code; the child maps it to 1. Argument-binding and PowerShell-version failures are handled by the PowerShell host.

A successful match does not imply successful training. A later failed exit is available through `-WaitFor Exit` or `Status`. Native `$LASTEXITCODE` is propagated; explicitly exit with your intended code when a script runs several native commands.

## Long waits in Codex: configure both layers

The PowerShell wait deadline and the Codex tool return windows are separate. `-TimeoutSeconds 0` permits an indefinite event wait but cannot change Codex's tool or turn limits.

On Codex versions that support it, put this setting at the **top level** of your Codex `config.toml`, before any table headers, then start a new Codex session:

```toml
background_terminal_max_timeout = 3600000
```

This raises the maximum empty `write_stdin` wait window to one hour. It does not automatically request one hour. The documented default is 300000 milliseconds; the older `background_terminal_timeout` key has been replaced. See the [official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

Give the agent these instructions:

```text
Start the producer once with Wait-CommandOutput.ps1. Disable the script deadline
with -TimeoutSeconds 0 and retain its JobPath. Prefer -WaitFor Exit when the task
requires the final command result rather than an intermediate milestone.

If exec_command returns session_id, resume that SAME session with write_stdin,
chars="", and the longest yield_time_ms allowed by the tool and session policy.
With a configured one-hour cap and a compatible tool schema, request 3600000.
Prefer a direct write_stdin tool if available.

If calls are wrapped in functions.exec, ALSO request the longest allowed OUTER
window in its @exec pragma and subsequent functions.wait calls. Resume the
existing CELL ID while its nested call is pending; do not duplicate write_stdin.
The CELL ID and terminal SESSION ID are different identifiers.

A yielded wait window is not task completion. Continue the authorized wait;
do not end turns with unchanged "still running" summaries. Report meaningful
milestones, completion, failures, or required user action. Follow higher-priority
progress-update requirements. Do not restart training or poll its logs.
```

For a client that permits a one-hour outer window, a code-mode call looks like:

```javascript
// @exec: {"yield_time_ms": 3600000, "max_output_tokens": 1000}
text(await tools.write_stdin({
    session_id: savedSessionId,
    chars: "",
    yield_time_ms: 3600000,
    max_output_tokens: 1000
}));
```

Replace `savedSessionId` with the actual returned session ID. If the outer call yields a cell ID, continue that cell with `functions.wait` and the longest permitted outer window. Always await nested promises.

**The config setting controls only `write_stdin`.** An inner one-hour wait wrapped in outer 60000-ms waits still wakes the agent every minute. If the client or session instructions mandate shorter outer waits, this script and config cannot eliminate those wakeups. The script also cannot prevent an agent from ending its turn or guarantee a background terminal will resume an idle agent.

In the Windows tool schema used during development, the initial `exec_command` window is capped at 30 seconds. Requesting an hour there does not extend that initial cap; use the returned session.

## Optional persistent environment variable

Choose a stable installation path and save it for the current Windows user:

```powershell
$scriptPath = (Resolve-Path -LiteralPath .\Wait-CommandOutput.ps1).ProviderPath
[Environment]::SetEnvironmentVariable('CODEX_WAIT_COMMAND_OUTPUT', $scriptPath, 'User')
$env:CODEX_WAIT_COMMAND_OUTPUT = $scriptPath
```

Existing Codex or terminal processes may retain their previous environment. Restart them, or refresh the current command shell explicitly:

```powershell
$env:CODEX_WAIT_COMMAND_OUTPUT =
    [Environment]::GetEnvironmentVariable('CODEX_WAIT_COMMAND_OUTPUT', 'User')

& $env:CODEX_WAIT_COMMAND_OUTPUT -Command 'python -u train.py' `
    -Pattern 'training complete' -Literal -TimeoutSeconds 0
```

## Matching, recovery, and limits

- Use `-Literal` for a substring, or omit it for a .NET regular expression. Matching ignores case by default; `-CaseSensitive` changes that. `-Stream Stdout` or `Stderr` selects one stream; the default `Any` watches both separately.
- Each stream has a bounded rolling match window: `-MaxBufferChars` defaults to 65536. Regex evaluations have a 1000-ms timeout by default. Patterns spanning more than the window cannot be guaranteed; regex anchors refer to the moving window. Full-line patterns should require an emitted newline.
- A fresh PowerShell child inherits environment variables, but not the caller's variables or functions. Profiles are disabled and input is noninteractive. The default working directory is the caller's filesystem directory; set `-WorkingDirectory` explicitly when needed.
- stdout and stderr are captured as UTF-8. Configure native producers accordingly. There is no guaranteed combined ordering between the two streams, and ANSI escapes are retained.
- Named events wake live waiters; atomic state files serve late or multiple waiters. Supervisor PID and start-time checks detect crashes and recycled PIDs.
- Wait timeout and ordinary waiter exit leave the supervisor running. OS shutdown, logoff, sandbox teardown, or external process termination can still stop it. Use a service or scheduler if those lifetimes must be survived.
- Only processes launched through this script can be monitored. It cannot retroactively attach to an arbitrary existing process's stdout.
- Avoid detached grandchildren that inherit the output pipes. The final pipe drain has a bounded timeout, and monitor failures stop the owned command tree where possible.
- Logs are not rotated: provision disk space and keep job folders private when commands or logs contain sensitive data.

Job directories contain `request.json`, `command.ps1`, process identities, `stdout.log`, `stderr.log`, and durable match/completion records. Keep these for diagnosis; they are not intended for source control.

## Verification

Run the process-level integration checks from a Windows PowerShell 7 shell:

```powershell
pwsh -NoProfile -File .\tests\Integration.Tests.ps1
```

The checks cover built-in help, Unicode and fragmented output, stderr filtering, post-match draining, timeout recovery, simultaneous waiters, high-volume output, command failures, regex timeouts, supervisor crashes, and compact versus verbose results. Scratch job directories are saved under `work/`; the test cleans up its own live processes.

A separate observed Codex run completed a full 3600-second wait with both the inner and outer windows set to one hour, without intermediate outer wait calls or final status replies. This is evidence for that client/session, not a guarantee against every host limit.
