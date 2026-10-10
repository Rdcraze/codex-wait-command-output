#requires -Version 7.2

<#
.SYNOPSIS
Run a PowerShell command and wait for matching output without polling its log.
.DESCRIPTION
Windows + PowerShell 7.2 or later, in the same Windows logon session. One
self-contained file; no modules required.
A hidden supervisor launches the command, drains stdout and stderr concurrently,
and writes UTF-8 logs. Matching uses incoming text chunks, including output that
has no newline. A named Windows event wakes the waiter. There are no timer-based
log checks, heartbeat messages, or agent-side searches for the pattern.

Run = start and wait; Start = start and return a durable JobPath; Wait = reconnect;
Status = read a snapshot. Worker is internal. Match detection does NOT stop the
command. The supervisor keeps draining and logging output until the command exits.
Wait timeout / Ctrl+C stops only the waiter. Use Wait again with the SAME JobPath;
do not restart training. Each job directory must be new and is retained for review.

Only commands started through this script can be monitored. An arbitrary existing
process's stdout cannot be attached after launch. To monitor an existing training
run, arrange output redirection/IPC before starting it; this script is a launcher.
PowerShell variables/functions from the caller are not inherited. Use a script
file, explicit arguments, or environment variables. Environment is inherited at
launch; profiles are disabled; commands are noninteractive.

TIMEOUTS AND CODEX AGENT INSTRUCTIONS (read before long waits):
1. This script defaults to a 600-second WAIT deadline. -TimeoutSeconds 0 disables
   it, including silent multi-hour training. It never imposes a training deadline.
2. With exec_command, yield_time_ms is a tool return window, not this script's
   deadline. In the tool schema used to develop this script, the Windows initial
   window is 10000..30000 ms. If it returns session_id, retain it and resume with
   write_stdin, chars="", yield_time_ms=300000 (default maximum in that schema).
   Use the longest permitted window when appropriate, rather than frequent checks.
   Do not launch another waiter on every tool return. Do not send Ctrl+C, terminate
   the exec cell, or restart the producer merely because a tool yielded.
3. On Codex versions that support it, edit the TOP LEVEL of your Codex config.toml:
       background_terminal_max_timeout = 3600000
   This raises the maximum EMPTY write_stdin wait window to one hour. Request that
   duration explicitly if the exposed tool schema allows it, and start a new Codex
   session after configuration changes. A larger cap does not change a requested
   short window. The older key background_terminal_timeout has been replaced.
   This script neither edits Codex settings nor overrides session policy.
4. A script cannot override a hard host/tool/turn timeout or promise an unlimited
   single tool call. If the host still caps waits, resume the same session at its
   allowed maximum. In functions.exec code mode, await the nested exec_command or
   write_stdin call. If the OUTER tool returns a running CELL ID, resume it with
   functions.wait; that ID is different from an exec_command SESSION ID.
   IMPORTANT: background_terminal_max_timeout controls ONLY write_stdin. It does
   NOT lengthen the OUTER functions.exec/functions.wait window. An inner one-hour
   wait wrapped in outer 60000-ms waits still wakes the agent every minute.
   Prefer direct write_stdin calls if available, avoiding an outer cell entirely.
   Otherwise request the longest OUTER yield_time_ms permitted by that tool AND
   the session instructions, on both the initial exec pragma and subsequent wait
   calls. If either layer mandates short waits, script/config changes cannot
   eliminate those agent wakeups. Do not evade session limits or claim otherwise.
   An outer yield does not mean that training completed. Resume the existing cell;
   do not start another write_stdin while that cell's call is still pending.
   Do not leave nested promises unawaited: they are discarded when the cell ends.
5. For recovery after a waiter is interrupted, use Start, save its JobPath, and
   invoke Wait -JobPath <same path> -TimeoutSeconds 0. The worker is detached from
   ordinary waiter exit, but Windows logoff/reboot, sandbox teardown, job-object
   cleanup, or process termination can still kill it. Use a service/job scheduler
   if training must survive those events. Reconnecting never reruns the command.
6. An unchanged wait result is not task completion. Do not end a turn with repeated
   'still running' summaries just because a wait window yielded. Continue the
   authorized wait unless the user stops it or the host forces the turn to end.
   Reuse the same session/cell; report meaningful matches, command completion,
   failures, or required user actions. Follow any higher-priority progress-update
   requirements. This script cannot control an agent's turn lifecycle, suppress
   mandatory updates, or make a returned background session wake an idle agent.

OUTPUT CONTRACT:
One compact JSON object on stdout per invocation; no live progress forwarded to
Codex. Default output includes State, JobPath, and only applicable fields:
OriginalExitCode, Stream/Text (match text capped at 160 characters), or a short
Error with original exception codes. Use the native -Verbose common parameter for
expanded JSON: match/exit timestamps, nested records, and bounded failure details.
It still emits only one JSON object, without streaming logs or full stack traces.
Detailed JSON may have different fields; inspect State and OriginalExitCode for
automation. Full match text (up to 4096 characters) and errors remain in state
files; all producer text remains in stdout.log/stderr.log.
For CommandFailed, this script exits with the ORIGINAL child exit code unchanged,
also exposed as top-level OriginalExitCode and Completion.ExitCode in JSON.
Other exit codes: 0 = Started/Status/Matched or successful Completed; 2 = NoMatch;
3 = Timeout; 5 = MonitorFailed/SupervisorLost; 64 = invocation or setup error.
Original command codes may overlap helper codes: use JSON State to distinguish.
Terminating PowerShell exceptions have no intrinsic process code; the child maps
them to 1. Monitor/setup exceptions preserve their type, HRESULT and native OS
error code (where available) in Failure. They are not training exit codes.
Argument binding / #requires failures are PowerShell host errors.
Match is a milestone, not proof of successful training. Use -WaitFor Exit for the
eventual command exit code. A failed exit after a match is visible in Status/Exit.
JobPath contains request.json, command.ps1, supervisor.json, child.json, stdout.log, stderr.log,
match.json (first match), and completion.json (final result). State files are
written atomically BEFORE events are signaled. Late and multiple waiters therefore
see the same result. Missing/crashed supervisor wakes a waiter via Process.Exited;
PID start times prevent attaching to a recycled process ID.

STREAMING LIMITS:
Pattern is a .NET regex, case-insensitive by default; -Literal selects a substring.
Each stream is matched separately against its last MaxBufferChars characters
(default 65536), with a per-evaluation regex time limit (default 1000 ms).
Patterns spanning a larger window cannot be guaranteed. Regex anchors refer to
this moving window, not complete lines or an entire log; use an explicit newline
if a complete line is required. An expression can match a partial emitted value.
Match Text is capped at 4096 characters and flags truncation. Logs retain all text
while disk space is available. ANSI escape sequences are not stripped.
The producer MUST flush its output: for Python use python -u or PYTHONUNBUFFERED=1;
for direct .NET writes call Flush(). Nothing can detect text still buffered inside
the producer. Write-Progress is not stdout: emit a text milestone instead. The
child uses UTF-8; configure native programs to emit UTF-8 too. No total ordering
between stdout/stderr is promised. Native nonzero LASTEXITCODE is propagated;
explicitly exit with the intended code in scripts with multiple native commands.
Do not spawn detached grandchildren inside the command: inherited pipe handles
can keep streams open after the command exits. DrainTimeoutSeconds bounds that
final drain; an overrun is reported as MonitorFailed. On monitor errors the owned
command tree is stopped where possible. Matching and waiter timeout do not stop it.
Treat job folders as private: command text and logs may contain sensitive data.

.PARAMETER Mode
Run (default), Start, Wait, Status; Worker is reserved for the hidden supervisor.
.PARAMETER Command
PowerShell source text to execute in a fresh pwsh process. Required for Run/Start.
.PARAMETER Pattern
Nonempty regex or literal substring. Required for Run/Start.
.PARAMETER JobPath
New directory for Run/Start, existing directory for Wait/Status. Defaults on start
to .wait-command-output/<random GUID> under the current directory.
.PARAMETER TimeoutSeconds
Wait deadline only; default 600, zero means infinite. Ignored by Start/Status.
.PARAMETER WaitFor
Match (default) returns at the first matching output; Exit waits for command exit.
.PARAMETER Literal
Use a literal substring rather than a regular expression.
.PARAMETER CaseSensitive
Require matching case. Default is ordinal/culture-invariant case-insensitive.
.PARAMETER Stream
Any (default), Stdout, or Stderr. Logs always capture both streams.
.PARAMETER WorkingDirectory
Child working directory; defaults to the caller's current filesystem directory.
.PARAMETER MaxBufferChars
Per-stream rolling match window, default 65536 characters, minimum 4096.
.PARAMETER RegexTimeoutMilliseconds
Limit each regex evaluation, default 1000 milliseconds. Not a wait deadline.
.PARAMETER DrainTimeoutSeconds
Maximum pipe drain time after command exit, default 10 seconds.
.EXAMPLE
Get-Help .\Wait-CommandOutput.ps1 -Full
Read these instructions directly from the script.
.EXAMPLE
.\Wait-CommandOutput.ps1 -Command '& .\train.ps1 -Epochs 100' -Pattern 'checkpoint saved' -Literal -TimeoutSeconds 0
Wait indefinitely for the milestone; training continues and logs remain in JobPath.
.EXAMPLE
$job = .\Wait-CommandOutput.ps1 -Mode Start -Command 'python -u train.py' -Pattern 'training complete' -Literal | ConvertFrom-Json
.\Wait-CommandOutput.ps1 -Mode Wait -JobPath $job.JobPath -TimeoutSeconds 0
.\Wait-CommandOutput.ps1 -Mode Wait -JobPath $job.JobPath -WaitFor Exit -TimeoutSeconds 0
Start once, wait for output, then wait for successful termination without restarting.
.EXAMPLE
.\Wait-CommandOutput.ps1 -Mode Status -JobPath 'C:\runs\training-001'
Read durable match/completion metadata once. This is an explicit snapshot, not a
polling loop. Choose a NEW JobPath for each training run.
.EXAMPLE
.\Wait-CommandOutput.ps1 -Mode Wait -JobPath 'C:\runs\training-001' -TimeoutSeconds 0 -Verbose
Opt into bounded detail when investigating a match or failure. Omit -Verbose for
the smallest result and keep the full logs on disk.
.LINK
https://learn.chatgpt.com/docs/config-file/config-reference
.LINK
https://learn.microsoft.com/dotnet/api/system.threading.eventwaithandle
.LINK
https://learn.microsoft.com/dotnet/api/system.io.streamreader.readasync
#>
[CmdletBinding()]
param(
    [ValidateSet('Run','Start','Wait','Status','Worker')][string]$Mode = 'Run',
    [string]$Command,
    [string]$Pattern,
    [string]$JobPath,
    [ValidateRange(0,2147483)][int]$TimeoutSeconds = 600,
    [ValidateSet('Match','Exit')][string]$WaitFor = 'Match',
    [switch]$Literal,
    [switch]$CaseSensitive,
    [ValidateSet('Any','Stdout','Stderr')][string]$Stream = 'Any',
    [string]$WorkingDirectory = (Get-Location).ProviderPath,
    [ValidateRange(4096,16777216)][int]$MaxBufferChars = 65536,
    [ValidateRange(1,60000)][int]$RegexTimeoutMilliseconds = 1000,
    [ValidateRange(1,300)][int]$DrainTimeoutSeconds = 10
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ShowDetails = $PSBoundParameters.ContainsKey('Verbose') -and [bool]$PSBoundParameters['Verbose']

function Write-AtomicJson([string]$Path, $Value) {
    $tempPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($tempPath, ($Value | ConvertTo-Json -Depth 12 -Compress), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tempPath, $Path, $true)
    } finally {
        if ([IO.File]::Exists($tempPath)) { [IO.File]::Delete($tempPath) }
    }
}
function Read-State([string]$Name) {
    $path = Join-Path $script:JobPath $Name
    if ([IO.File]::Exists($path)) { return [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    return $null
}
function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}
function Limit-Text([string]$Text, [int]$Length) {
    if ($Text.Length -le $Length) { return $Text }
    return $Text.Substring(0, $Length - 3) + '...'
}
function Emit-Result($Value, [int]$Code) {
    $compact = [ordered]@{ State = $Value.State; JobPath = $Value.JobPath }
    $completion = Get-Field $Value 'Completion'
    $match = Get-Field $Value 'Match'
    $originalCode = Get-Field $Value 'OriginalExitCode'
    if ($null -eq $originalCode -and $null -ne $completion -and $completion.State -eq 'Completed') {
        $originalCode = $completion.ExitCode
    }
    if ($null -ne $originalCode) { $compact.OriginalExitCode = $originalCode }
    if ($Value.State -eq 'Snapshot') {
        $compact.MatchSeen = $null -ne $match
        $compact.Terminal = $null -ne $completion
    }
    if ($null -ne $match) {
        $compact.Stream = $match.Stream
        $compact.Text = Limit-Text $match.Text 160
        if ($match.Text.Length -gt 160 -or $match.TextTruncated) { $compact.TextTruncated = $true }
    }
    $failure = Get-Field $Value 'Failure'
    if ($null -eq $failure) { $failure = Get-Field $completion 'Failure' }
    $errorText = Get-Field $Value 'Error'
    if ($null -ne $failure) {
        $errorText = $failure.Message
        $compact.ExceptionType = $failure.ExceptionType
        $compact.HResult = $failure.HResult
        if ($null -ne $failure.NativeErrorCode) { $compact.NativeErrorCode = $failure.NativeErrorCode }
    } elseif (-not $errorText) { $errorText = Get-Field $completion 'Error' }
    if ($errorText) { $compact.Error = Limit-Text $errorText 240 }
    if ($script:ShowDetails) {
        # Clone before bounding the displayed values. Durable evidence stays intact.
        $detail = $Value | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json -AsHashtable
        if ($null -ne $match) {
            $detail.Match.Text = Limit-Text $match.Text 512
            $detail.Match.TextTruncated = $match.Text.Length -gt 512 -or $match.TextTruncated
        }
        foreach ($record in @($detail, $detail['Completion'])) {
            if ($null -eq $record) { continue }
            if ($record.ContainsKey('Error')) { $record.Error = Limit-Text $record.Error 512 }
            if ($record.ContainsKey('Failure')) {
                $record.Failure.Message = Limit-Text $record.Failure.Message 400
                if ($record.Failure.ContainsKey('ScriptStackTrace')) { $record.Failure.ScriptStackTrace = Limit-Text $record.Failure.ScriptStackTrace 400 }
                # Exception.ToString duplicates the useful Failure fields.
                $record.Remove('Error')
            }
        }
        Write-Output ($detail | ConvertTo-Json -Depth 12 -Compress)
    } else {
        Write-Output ($compact | ConvertTo-Json -Depth 6 -Compress)
    }
    exit $Code
}
function Get-FailureDetails([Management.Automation.ErrorRecord]$Record) {
    $cause = $Record.Exception
    while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
    $nativeCode = if ($cause -is [ComponentModel.Win32Exception]) { $cause.NativeErrorCode } else { $null }
    return @{
        ExceptionType = $cause.GetType().FullName; Message = $cause.Message;
        HResult = $cause.HResult; NativeErrorCode = $nativeCode;
        FullyQualifiedErrorId = $Record.FullyQualifiedErrorId; ScriptStackTrace = $Record.ScriptStackTrace
    }
}

# C# callbacks execute on .NET threads. PowerShell scriptblock callbacks on those
# threads have no runspace; keep the asynchronous I/O and lifecycle callbacks here.
function Initialize-Runtime {
    if ('CommandOutputWait.V1.Monitor' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace CommandOutputWait.V1 {
    public sealed class ProcessWatch : IDisposable {
        public readonly ManualResetEvent Exited = new ManualResetEvent(false);
        private readonly Process process;
        private readonly EventHandler handler;
        public ProcessWatch(int pid, long startTicks) {
            process = Process.GetProcessById(pid);
            try {
                if (process.StartTime.ToUniversalTime().Ticks != startTicks)
                    throw new InvalidOperationException("Supervisor PID has been recycled.");
                handler = (s, e) => Exited.Set();
                process.Exited += handler;
                process.EnableRaisingEvents = true;
                if (process.HasExited) Exited.Set();
            } catch { process.Dispose(); Exited.Dispose(); throw; }
        }
        public void Dispose() {
            process.Exited -= handler;
            // Release the Process before its callback's wait handle.
            process.Dispose();
            // Do not dispose Exited here: a queued .NET callback may still set it.
            // Its SafeHandle is reclaimed with this object by the GC.
        }
    }

    public sealed class Monitor {
        private readonly string dir, pattern, selectedStream;
        private readonly bool literal, caseSensitive;
        private readonly int windowSize;
        private readonly Regex regex;
        private readonly object gate = new object();
        private bool matched;
        private readonly EventWaitHandle matchEvent, exitEvent;
        public Monitor(string directory, string eventBase, string matchPattern,
                       bool literalMatch, bool sensitive, string stream,
                       int maxChars, int regexMs) {
            dir = directory; pattern = matchPattern; literal = literalMatch;
            caseSensitive = sensitive; selectedStream = stream; windowSize = maxChars;
            if (!literal) regex = new Regex(pattern,
                RegexOptions.CultureInvariant | (sensitive ? RegexOptions.None : RegexOptions.IgnoreCase),
                TimeSpan.FromMilliseconds(regexMs));
            matchEvent = new EventWaitHandle(false, EventResetMode.ManualReset, eventBase + ".match");
            exitEvent = new EventWaitHandle(false, EventResetMode.ManualReset, eventBase + ".exit");
        }
        public static void Atomic(string path, object value) {
            string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try {
                File.WriteAllText(temp, JsonSerializer.Serialize(value), new UTF8Encoding(false));
                File.Move(temp, path, true);
            } finally { if (File.Exists(temp)) File.Delete(temp); }
        }
        private async Task Pump(StreamReader reader, string stream, CancellationToken cancellation) {
            using (var log = new StreamWriter(Path.Combine(dir, stream.ToLowerInvariant() + ".log"),
                                             false, new UTF8Encoding(false))) {
                log.AutoFlush = true;
                char[] chunk = new char[4096];
                var window = new StringBuilder();
                while (true) {
                    int count = await reader.ReadAsync(chunk.AsMemory(), cancellation).ConfigureAwait(false);
                    if (count == 0) break;
                    await log.WriteAsync(chunk.AsMemory(0, count), cancellation).ConfigureAwait(false);
                    lock (gate) {
                        if (matched || (selectedStream != "Any" && selectedStream != stream)) continue;
                        window.Append(chunk, 0, count);
                        if (window.Length > windowSize) window.Remove(0, window.Length - windowSize);
                        string text = window.ToString();
                        string value;
                        if (literal) {
                            int index = text.IndexOf(pattern, caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase);
                            if (index < 0) continue;
                            value = text.Substring(index, pattern.Length);
                        } else {
                            Match found = regex.Match(text);
                            if (!found.Success) continue;
                            value = found.Value;
                        }
                        Atomic(Path.Combine(dir, "match.json"), new {
                            State = "Matched", Stream = stream,
                            Text = value.Length > 4096 ? value.Substring(0, 4096) : value,
                            TextTruncated = value.Length > 4096,
                            TimestampUtc = DateTime.UtcNow.ToString("o")
                        });
                        matched = true;
                        matchEvent.Set();
                    }
                }
            }
        }
        public void Run(string shell, string commandFile, string workDir, int drainSeconds) {
            RunAsync(shell, commandFile, workDir, drainSeconds).GetAwaiter().GetResult();
        }
        private async Task RunAsync(string shell, string commandFile, string workDir, int drainSeconds) {
            Process process = null;
            Task pumps = null;
            using (var cancellation = new CancellationTokenSource()) {
                try {
                    var info = new ProcessStartInfo(shell) {
                        UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = workDir,
                        RedirectStandardOutput = true, RedirectStandardError = true,
                        RedirectStandardInput = true, StandardOutputEncoding = new UTF8Encoding(false),
                        StandardErrorEncoding = new UTF8Encoding(false)
                    };
                    foreach (string arg in new [] { "-NoLogo", "-NoProfile", "-NonInteractive", "-File", commandFile })
                        info.ArgumentList.Add(arg);
                    process = Process.Start(info);
                    process.StandardInput.Close();
                    Atomic(Path.Combine(dir, "child.json"), new {
                        Pid = process.Id, StartTicksUtc = process.StartTime.ToUniversalTime().Ticks
                    });
                    // If either pump faults, wake immediately even if its sibling
                    // is blocked on a quiet pipe. Task.WhenAll alone would hang.
                    var pumpFailure = new TaskCompletionSource<Exception>(TaskCreationOptions.RunContinuationsAsynchronously);
                    Task stdout = Pump(process.StandardOutput, "Stdout", cancellation.Token);
                    Task stderr = Pump(process.StandardError, "Stderr", cancellation.Token);
                    Action<Task> detect = t => { if (t.IsFaulted) pumpFailure.TrySetResult(t.Exception.GetBaseException()); };
                    _ = stdout.ContinueWith(detect, TaskScheduler.Default);
                    _ = stderr.ContinueWith(detect, TaskScheduler.Default);
                    pumps = Task.WhenAll(stdout, stderr);
                    Task exited = process.WaitForExitAsync();
                    Task first = await Task.WhenAny(exited, pumpFailure.Task).ConfigureAwait(false);
                    if (first == pumpFailure.Task) throw await pumpFailure.Task.ConfigureAwait(false);
                    await exited.ConfigureAwait(false);
                    Task drained = await Task.WhenAny(pumps, Task.Delay(TimeSpan.FromSeconds(drainSeconds))).ConfigureAwait(false);
                    if (drained != pumps) throw new IOException("Pipe drain timed out; a descendant may still hold stdout/stderr open.");
                    await pumps.ConfigureAwait(false);
                    Atomic(Path.Combine(dir, "completion.json"), new {
                        State = "Completed", ExitCode = process.ExitCode,
                        TimestampUtc = DateTime.UtcNow.ToString("o")
                    });
                } catch (Exception error) {
                    cancellation.Cancel();
                    if (process != null) {
                        try { if (!process.HasExited) process.Kill(true); } catch { }
                    }
                    // Finish I/O teardown before releasing event handles used by Pump.
                    if (pumps != null) { try { await pumps.ConfigureAwait(false); } catch { } }
                    Atomic(Path.Combine(dir, "completion.json"), new {
                        State = "MonitorFailed", Error = error.ToString(),
                        Failure = new { ExceptionType = error.GetType().FullName,
                            Message = error.Message, HResult = error.HResult,
                            NativeErrorCode = error is System.ComponentModel.Win32Exception
                                ? (int?)((System.ComponentModel.Win32Exception)error).NativeErrorCode : null },
                        TimestampUtc = DateTime.UtcNow.ToString("o")
                    });
                } finally {
                    try { exitEvent.Set(); matchEvent.Set(); }
                    finally { if (process != null) process.Dispose(); exitEvent.Dispose(); matchEvent.Dispose(); }
                }
            }
        }
    }
}
'@
}

function Get-WaitResult {
    $match = Read-State 'match.json'
    $completion = Read-State 'completion.json'
    $originalCode = if ($null -ne $completion -and $completion.State -eq 'Completed') { $completion.ExitCode } else { $null }
    if ($WaitFor -eq 'Match' -and $null -ne $match) {
        return @{ Code = 0; Value = @{ State = 'Matched'; JobPath = $JobPath; OriginalExitCode = $originalCode; Match = $match; Completion = $completion } }
    }
    if ($null -ne $completion) {
        $state = $completion.State
        $code = 5
        if ($state -eq 'Completed') {
            if ($completion.ExitCode -ne 0) { $state = 'CommandFailed'; $code = [int]$completion.ExitCode }
            elseif ($WaitFor -eq 'Match') { $state = 'NoMatch'; $code = 2 }
            else { $code = 0 }
        }
        return @{ Code = $code; Value = @{ State = $state; JobPath = $JobPath; OriginalExitCode = $originalCode; Match = $match; Completion = $completion } }
    }
    return $null
}

try {
    if (-not $IsWindows) { throw 'Named-event supervision in this script requires Windows.' }
    if ($Mode -in @('Run','Start')) {
        if ([string]::IsNullOrWhiteSpace($Command)) { throw '-Command is required for Run/Start.' }
        if ([string]::IsNullOrEmpty($Pattern)) { throw '-Pattern must be nonempty for Run/Start.' }
        if (-not $Literal) {
            $options = [Text.RegularExpressions.RegexOptions]::CultureInvariant
            if (-not $CaseSensitive) { $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase }
            $null = [Text.RegularExpressions.Regex]::new($Pattern, $options, [timespan]::FromMilliseconds($RegexTimeoutMilliseconds))
        }
        $WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).ProviderPath
        if (-not [IO.Directory]::Exists($WorkingDirectory)) { throw 'WorkingDirectory must be a directory.' }
        $jobId = [guid]::NewGuid().ToString('N')
        if (-not $JobPath) { $JobPath = Join-Path (Get-Location).ProviderPath ".wait-command-output\$jobId" }
        $JobPath = [IO.Path]::GetFullPath($JobPath)
        # Exclusive marker creation arbitrates concurrent attempts at the same path.
        if (Test-Path -LiteralPath $JobPath) { throw 'JobPath already exists; use a new job directory, or Mode Wait to reconnect.' }
        $null = [IO.Directory]::CreateDirectory($JobPath)
        $marker = [IO.File]::Open((Join-Path $JobPath 'owner.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $marker.Dispose()
        $shellPath = (Get-Process -Id $PID).Path
        $request = @{
            Version = 1; EventBase = "Local\CodexCommandOutput_$jobId";
            Command = $Command; Pattern = $Pattern; Literal = [bool]$Literal;
            CaseSensitive = [bool]$CaseSensitive; Stream = $Stream;
            WorkingDirectory = $WorkingDirectory; ShellPath = $shellPath;
            MaxBufferChars = $MaxBufferChars; RegexTimeoutMilliseconds = $RegexTimeoutMilliseconds;
            DrainTimeoutSeconds = $DrainTimeoutSeconds
        }
        Write-AtomicJson (Join-Path $JobPath 'request.json') $request
        $launch = [Diagnostics.ProcessStartInfo]::new($shellPath)
        $launch.UseShellExecute = $false
        $launch.CreateNoWindow = $true
        foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Mode','Worker','-JobPath',$JobPath)) {
            $launch.ArgumentList.Add($arg)
        }
        $supervisor = [Diagnostics.Process]::Start($launch)
        try {
            Write-AtomicJson (Join-Path $JobPath 'supervisor.json') @{
                Pid = $supervisor.Id; StartTicksUtc = $supervisor.StartTime.ToUniversalTime().Ticks
            }
        } catch {
            try { $supervisor.Kill($true) } catch { }
            throw
        } finally { $supervisor.Dispose() }
        if ($Mode -eq 'Start') { Emit-Result @{ State = 'Started'; JobPath = $JobPath } 0 }
    } else {
        if (-not $JobPath) { throw '-JobPath is required for Wait/Status.' }
        $JobPath = (Resolve-Path -LiteralPath $JobPath).ProviderPath
        $request = Read-State 'request.json'
        if ($null -eq $request -or $request.Version -ne 1) { throw 'Missing/unsupported request.json in JobPath.' }
    }

    if ($Mode -eq 'Worker') {
        try {
            Initialize-Runtime
            # Embed command as base64 data, never interpolate it into shell arguments.
            $sourceData = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($request.Command))
            $childSource = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$global:LASTEXITCODE = 0
try {
    $source = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__SOURCE__'))
    & ([scriptblock]::Create($source))
    exit $global:LASTEXITCODE
} catch {
    [Console]::Error.WriteLine($_.ToString())
    exit 1
}
'@
            $childSource = $childSource.Replace('__SOURCE__', $sourceData)
            # A script file avoids Windows' command-line length limit for long source.
            $commandFile = Join-Path $JobPath 'command.ps1'
            [IO.File]::WriteAllText($commandFile, $childSource, [Text.UTF8Encoding]::new($false))
            $monitor = [CommandOutputWait.V1.Monitor]::new($JobPath, $request.EventBase, $request.Pattern,
                $request.Literal, $request.CaseSensitive, $request.Stream, $request.MaxBufferChars, $request.RegexTimeoutMilliseconds)
            $monitor.Run($request.ShellPath, $commandFile, $request.WorkingDirectory, $request.DrainTimeoutSeconds)
        } catch {
            Write-AtomicJson (Join-Path $JobPath 'completion.json') @{
                State = 'MonitorFailed'; Error = $_.ToString(); Failure = Get-FailureDetails $_;
                TimestampUtc = [DateTime]::UtcNow.ToString('o')
            }
            foreach ($suffix in @('.match','.exit')) {
                $wake = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $request.EventBase + $suffix)
                try { $null = $wake.Set() } finally { $wake.Dispose() }
            }
        }
        exit 0
    }

    if ($Mode -eq 'Status') {
        Emit-Result @{ State = 'Snapshot'; JobPath = $JobPath; Supervisor = Read-State 'supervisor.json';
            Child = Read-State 'child.json'; Match = Read-State 'match.json'; Completion = Read-State 'completion.json' } 0
    }

    # Creating the event BEFORE reading state closes the start/read/wait race.
    # Manual-reset events also permit multiple concurrent waiters.
    Initialize-Runtime
    $suffix = if ($WaitFor -eq 'Match') { '.match' } else { '.exit' }
    $signal = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $request.EventBase + $suffix)
    $watch = $null
    try {
        $result = Get-WaitResult
        if ($null -ne $result) { Emit-Result $result.Value $result.Code }
        $identity = Read-State 'supervisor.json'
        try {
            if ($null -eq $identity) { throw 'Supervisor identity is missing.' }
            $watch = [CommandOutputWait.V1.ProcessWatch]::new($identity.Pid, $identity.StartTicksUtc)
        } catch {
            $result = Get-WaitResult
            if ($null -ne $result) { Emit-Result $result.Value $result.Code }
            Emit-Result @{ State = 'SupervisorLost'; JobPath = $JobPath; Error = $_.ToString(); Failure = Get-FailureDetails $_ } 5
        }
        $handles = [Threading.WaitHandle[]]@($signal, $watch.Exited)
        $waitMilliseconds = if ($TimeoutSeconds -eq 0) { -1 } else { $TimeoutSeconds * 1000 }
        $index = [Threading.WaitHandle]::WaitAny($handles, $waitMilliseconds)
        # Recheck durable state even after timeout/death to honor a racing commit.
        $result = Get-WaitResult
        if ($null -ne $result) { Emit-Result $result.Value $result.Code }
        if ($index -eq [Threading.WaitHandle]::WaitTimeout) {
            Emit-Result @{ State = 'Timeout'; JobPath = $JobPath; WaitFor = $WaitFor;
                Error = 'Wait deadline elapsed. The producer was not stopped; reconnect using the same JobPath.' } 3
        }
        Emit-Result @{ State = 'SupervisorLost'; JobPath = $JobPath;
            Error = 'Supervisor exited or signaled without a committed result. Inspect the job folder.' } 5
    } finally {
        if ($null -ne $watch) { $watch.Dispose() }
        $signal.Dispose()
    }
} catch {
    Emit-Result @{ State = 'Error'; JobPath = $JobPath; Error = $_.ToString(); Failure = Get-FailureDetails $_ } 64
}
