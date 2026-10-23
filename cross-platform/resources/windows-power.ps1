param(
    [ValidateSet('Status', 'Sleep', 'DisplayOff', 'Lock', 'LidGuard', 'LidRestore')][string]$Action = 'Status',
    [ValidateSet('keep', 'sleep')][string]$Mode = 'keep',
    [int]$ParentPid = 0,
    [string]$Lease = '',
    [string]$Token = '',
    [string]$StateDir = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$Buttons = '4f971e89-eebd-4455-a8de-9e59040e7347'
$LidAction = '5ca83367-6e45-459f-a27b-476b1d01c936'
$GuidPattern = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
$script:Mutex = $null
$script:MutexOwned = $false
$script:SnapshotFile = $null
$script:StatusFile = $null
$script:RestoreFailed = $false

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SleepDockNative {
    [StructLayout(LayoutKind.Sequential)] public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public uint BatteryLifeTime, BatteryFullLifeTime;
    }
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize, dwTime; }
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("powrprof.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.U1)]
    public static extern bool SetSuspendState([MarshalAs(UnmanagedType.U1)] bool hibernate,
        [MarshalAs(UnmanagedType.U1)] bool forceCritical, [MarshalAs(UnmanagedType.U1)] bool disableWakeEvent);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool LockWorkStation();
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint message, UIntPtr wParam, IntPtr lParam, uint flags, uint timeout, out UIntPtr result);
    [StructLayout(LayoutKind.Sequential)] private struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] private struct TOKEN_PRIVILEGES { public uint Count; public LUID Id; public uint Attributes; }
    [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool LookupPrivilegeValue(string system, string name, out LUID id);
    [DllImport("advapi32.dll", SetLastError=true)] private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES privileges, uint size, IntPtr previous, IntPtr returned);
    public static bool EnableSuspendPrivilege() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return false;
        try {
            LUID id;
            if (!LookupPrivilegeValue(null, "SeShutdownPrivilege", out id)) return false;
            TOKEN_PRIVILEGES privilege = new TOKEN_PRIVILEGES { Count = 1, Id = id, Attributes = 2 };
            return AdjustTokenPrivileges(token, false, ref privilege, 0, IntPtr.Zero, IntPtr.Zero) && Marshal.GetLastWin32Error() == 0;
        } finally { CloseHandle(token); }
    }
}
'@

function Result($Object) { $Object | ConvertTo-Json -Compress -Depth 6 | Write-Output }
function Native-Error([string]$Description) {
    throw "$Description (Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
}
function Power-Status {
    $power = New-Object SleepDockNative+SYSTEM_POWER_STATUS
    if (-not [SleepDockNative]::GetSystemPowerStatus([ref]$power)) { Native-Error 'Cannot read system power status' }
    $battery = -1
    if ($power.BatteryLifePercent -le 100 -and ($power.BatteryFlag -band 128) -eq 0) { $battery = [int]$power.BatteryLifePercent }
    $pluggedIn = $null
    if ($power.ACLineStatus -eq 1) { $pluggedIn = $true }
    elseif ($power.ACLineStatus -eq 0) { $pluggedIn = $false }
    $last = New-Object SleepDockNative+LASTINPUTINFO
    $last.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($last)
    $idle = $null
    if ([SleepDockNative]::GetLastInputInfo([ref]$last)) {
        $tick = [BitConverter]::ToUInt32([BitConverter]::GetBytes([Environment]::TickCount), 0)
        $idle = (([long]$tick - [long]$last.dwTime + 4294967296) % 4294967296) / 1000.0
    }
    return @{ ok = $true; battery = $battery; pluggedIn = $pluggedIn; idleSeconds = $idle }
}
function Run-PowerCfg([string[]]$Arguments) {
    # Arguments here are only fixed switches, checked GUIDs and small integers.
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '^(/[a-zA-Z]+|[0-9a-fA-F-]+)$') { throw 'Invalid powercfg argument' }
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    $start.Arguments = [string]::Join(' ', $Arguments)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Cannot start powercfg' }
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(8000)) { $process.Kill(); throw 'powercfg timed out' }
        $output = $outputTask.Result
        $detail = $errorTask.Result
        if ($process.ExitCode -ne 0) { throw "powercfg failed ($($process.ExitCode)); check power-plan permissions. $detail $output" }
        return $output
    } finally { $process.Dispose() }
}
function Active-Scheme {
    $output = Run-PowerCfg -Arguments @('/getactivescheme')
    $match = [regex]::Match($output, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw 'Cannot read current power scheme' }
    return $match.Value
}
function Read-Lid([string]$Scheme) {
    if ($Scheme -notmatch $GuidPattern) { throw 'Invalid saved power scheme' }
    $output = Run-PowerCfg -Arguments @('/query', $Scheme, $Buttons, $LidAction)
    # The final two hexadecimal indices are AC and DC, independent of UI language.
    $matches = [regex]::Matches($output, '(?im)0x([0-9a-f]{1,8})\s*$')
    if ($matches.Count -lt 2) { throw 'Cannot read original AC/DC lid action' }
    $ac = [Convert]::ToInt32($matches[$matches.Count - 2].Groups[1].Value, 16)
    $dc = [Convert]::ToInt32($matches[$matches.Count - 1].Groups[1].Value, 16)
    if ($ac -lt 0 -or $ac -gt 3 -or $dc -lt 0 -or $dc -gt 3) { throw 'Unsupported AC/DC lid action; no settings were changed' }
    return @{ ac = $ac; dc = $dc }
}
function Apply-Lid([string]$Scheme, [int]$AC, [int]$DC) {
    if ($Scheme -notmatch $GuidPattern -or $AC -lt 0 -or $AC -gt 3 -or $DC -lt 0 -or $DC -gt 3) { throw 'Invalid lid-action snapshot' }
    $null = Run-PowerCfg -Arguments @('/setacvalueindex', $Scheme, $Buttons, $LidAction, "$AC")
    $null = Run-PowerCfg -Arguments @('/setdcvalueindex', $Scheme, $Buttons, $LidAction, "$DC")
    # Do not switch the user's active scheme if they changed it while the guard ran.
    if ((Active-Scheme) -eq $Scheme) { $null = Run-PowerCfg -Arguments @('/setactive', $Scheme) }
    $readback = Read-Lid $Scheme
    if ($readback.ac -ne $AC -or $readback.dc -ne $DC) { throw 'Lid-action readback did not match the requested value' }
}
function Check-RegularPath([string]$File, [bool]$MayNotExist = $false) {
    if (-not (Test-Path -LiteralPath $File)) {
        if ($MayNotExist) { return }
        throw "Required guard path does not exist: $File"
    }
    $item = Get-Item -LiteralPath $File -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Guard paths cannot be reparse points' }
}
function Write-AtomicJson([string]$File, $Value) {
    Check-RegularPath $File $true
    $temporary = "$File.new-$([Guid]::NewGuid().ToString())"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Compress -Depth 6), $Utf8)
        Move-Item -LiteralPath $temporary -Destination $File -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Guard-Status([string]$Status, [string]$Message = '', [bool]$RestoreFailed = $false) {
    if ($script:StatusFile) {
        Write-AtomicJson $script:StatusFile @{ token = $Token; status = $Status; message = $Message; restoreFailed = $RestoreFailed }
    }
}
function Open-GuardLock {
    if (-not [IO.Path]::IsPathRooted($StateDir)) { throw 'Guard state directory must be absolute' }
    $null = [IO.Directory]::CreateDirectory($StateDir)
    Check-RegularPath $StateDir
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $script:Mutex = New-Object Threading.Mutex -ArgumentList $false, "Global\SleepDock-LidGuard-$identity"
    try { $script:MutexOwned = $script:Mutex.WaitOne(12000) }
    catch [Threading.AbandonedMutexException] { $script:MutexOwned = $true }
    if (-not $script:MutexOwned) { throw 'Another SleepDock lid guard is still active' }
    $script:SnapshotFile = Join-Path $StateDir 'state.json'
    Check-RegularPath $script:SnapshotFile $true
}
function Restore-Snapshot {
    if (-not (Test-Path -LiteralPath $script:SnapshotFile)) { return }
    Check-RegularPath $script:SnapshotFile
    try {
        $state = Get-Content -LiteralPath $script:SnapshotFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.version -ne 1 -or $state.scheme -notmatch $GuidPattern -or
            $state.ac -notin @(0, 1, 2, 3) -or $state.dc -notin @(0, 1, 2, 3)) {
            throw 'Saved lid-action snapshot is invalid; retained for manual inspection'
        }
        Apply-Lid $state.scheme ([int]$state.ac) ([int]$state.dc)
        Remove-Item -LiteralPath $script:SnapshotFile -Force
    } catch { $script:RestoreFailed = $true; throw }
}
function Valid-Lease {
    try {
        Check-RegularPath $Lease
        $item = Get-Item -LiteralPath $Lease -Force
        $age = ([DateTime]::UtcNow - $item.LastWriteTimeUtc).TotalSeconds
        if ($age -lt -5 -or $age -gt 15 -or $item.Length -gt 512) { return $false }
        $line = [IO.File]::ReadAllLines($Lease, $Utf8)[0]
        return $line -eq $Token
    } catch { return $false }
}
function Parent-Start {
    try { return (Get-Process -Id $ParentPid -ErrorAction Stop).StartTime.ToUniversalTime().Ticks }
    catch { return 0 }
}

try {
    switch ($Action) {
        'Status' { Result (Power-Status) }
        'Sleep' {
            if (-not [SleepDockNative]::EnableSuspendPrivilege()) { Native-Error 'Suspend privilege is unavailable in this account' }
            if (-not [SleepDockNative]::SetSuspendState($false, $false, $false)) { Native-Error 'System rejected suspend request' }
            Result @{ ok = $true }
        }
        'DisplayOff' {
            $result = [UIntPtr]::Zero
            $sent = [SleepDockNative]::SendMessageTimeout([IntPtr]65535, 0x112, [UIntPtr]0xF170, [IntPtr]2, 2, 1000, [ref]$result)
            if ($sent -eq [IntPtr]::Zero) { Native-Error 'Display power-off request timed out or was rejected' }
            Result @{ ok = $true }
        }
        'Lock' {
            if (-not [SleepDockNative]::LockWorkStation()) { Native-Error 'System rejected lock request' }
            Result @{ ok = $true }
        }
        'LidRestore' {
            Open-GuardLock
            Restore-Snapshot
            Result @{ ok = $true; message = 'Saved lid actions restored and verified' }
        }
        'LidGuard' {
            if ($ParentPid -le 0 -or $Token -notmatch $GuidPattern -or -not [IO.Path]::IsPathRooted($Lease)) { throw 'Invalid guard request' }
            Open-GuardLock
            $script:StatusFile = Join-Path $StateDir "$Token.status.json"
            # A previously killed watchdog leaves a snapshot. Restore it before taking a new one.
            Restore-Snapshot
            $initialParent = Parent-Start
            if ($initialParent -eq 0 -or -not (Valid-Lease)) { throw 'Guard request was cancelled before changing settings' }
            if ($Mode -eq 'keep' -and (Power-Status).pluggedIn -ne $true) { throw 'Keep-running lid mode requires confirmed AC power' }
            $scheme = Active-Scheme
            $original = Read-Lid $scheme
            Write-AtomicJson $script:SnapshotFile @{ version = 1; scheme = $scheme; ac = $original.ac; dc = $original.dc; token = $Token }
            Guard-Status 'applying'
            $reason = 'Lid guard released'
            try {
                if (-not (Valid-Lease) -or (Parent-Start) -ne $initialParent) { throw 'Guard request was cancelled before changing settings' }
                $value = 0
                if ($Mode -eq 'sleep') { $value = 1 }
                Apply-Lid $scheme $value $value
                if (-not (Valid-Lease) -or (Parent-Start) -ne $initialParent) { throw 'Guard request expired while applying settings' }
                Guard-Status 'active'
                while ((Valid-Lease) -and (Parent-Start) -eq $initialParent) {
                    if ((Active-Scheme) -ne $scheme) { $reason = 'Active power scheme changed; restored original lid actions'; break }
                    if ($Mode -eq 'keep' -and (Power-Status).pluggedIn -ne $true) { $reason = 'AC power disconnected; restored original lid actions'; break }
                    Start-Sleep -Seconds 2
                }
            } finally {
                Restore-Snapshot
                Guard-Status 'restored' $reason
            }
        }
    }
} catch {
    $message = $_.Exception.Message
    if ($Action -eq 'LidGuard') {
        try { Guard-Status 'error' $message $script:RestoreFailed } catch {}
    } else { Result @{ ok = $false; message = $message; restoreFailed = $script:RestoreFailed } }
    exit 1
} finally {
    if ($script:MutexOwned) { $script:Mutex.ReleaseMutex() }
    if ($script:Mutex) { $script:Mutex.Dispose() }
}
