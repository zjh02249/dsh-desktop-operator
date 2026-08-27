param(
    [Parameter(Mandatory = $true)]
    [string]$OperationPath
)

$ErrorActionPreference = "Stop"
$DefaultTextLimit = 500
$AccessibilityTreeMaxNodeCount = 1200
$AccessibilityTreeMaxDepth = 64

# Set output encoding to UTF-8 to properly handle non-ASCII characters
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

$captureHelperPath = Join-Path $PSScriptRoot "capture_helper.dll"
if (-not (Test-Path -LiteralPath $captureHelperPath -PathType Leaf)) {
    throw "Embedded Windows capture helper not found: $captureHelperPath"
}
[void][System.Reflection.Assembly]::LoadFrom($captureHelperPath)

$win32Source = @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class OCUWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION U;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool PostMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    private static extern IntPtr GetThreadDpiAwarenessContext();

    [DllImport("user32.dll")]
    private static extern bool AreDpiAwarenessContextsEqual(IntPtr first, IntPtr second);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, UInt32 command);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindowAsync(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attachThreadId, uint attachToThreadId, bool attach);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

    public static bool EnablePerMonitorV2DpiAwareness() {
        try {
            IntPtr perMonitorV2 = new IntPtr(-4);
            SetProcessDpiAwarenessContext(perMonitorV2);
            return AreDpiAwarenessContextsEqual(GetThreadDpiAwarenessContext(), perMonitorV2);
        } catch (EntryPointNotFoundException) {
            return false;
        }
    }

    public static uint GetEffectiveMonitorDpi(IntPtr hWnd) {
        try {
            IntPtr monitor = MonitorFromWindow(hWnd, 2);
            uint dpiX;
            uint dpiY;
            if (monitor != IntPtr.Zero && GetDpiForMonitor(monitor, 0, out dpiX, out dpiY) >= 0 && dpiX > 0) {
                return dpiX;
            }
        } catch (DllNotFoundException) {
        } catch (EntryPointNotFoundException) {
        }
        uint windowDpi = GetDpiForWindow(hWnd);
        return windowDpi == 0 ? 96u : windowDpi;
    }

    public static IntPtr[] EnumerateTopLevelWindows() {
        var handles = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            if (IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0) {
                handles.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return handles.ToArray();
    }

    public static string ReadWindowTitle(IntPtr hWnd) {
        int length = GetWindowTextLength(hWnd);
        if (length <= 0) return String.Empty;
        var value = new StringBuilder(length + 1);
        GetWindowText(hWnd, value, value.Capacity);
        return value.ToString();
    }

    private static void SendInputChecked(INPUT[] inputs) {
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != inputs.Length) {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SendInput did not enqueue the complete input sequence");
        }
    }

    private static INPUT MouseInput(uint flags, uint data) {
        var input = new INPUT();
        input.type = 0;
        input.U.mi.dwFlags = flags;
        input.U.mi.mouseData = data;
        return input;
    }

    private static INPUT KeyboardInput(ushort virtualKey, ushort scanCode, uint flags) {
        var input = new INPUT();
        input.type = 1;
        input.U.ki.wVk = virtualKey;
        input.U.ki.wScan = scanCode;
        input.U.ki.dwFlags = flags;
        return input;
    }

    public static IntPtr RootWindowAtPoint(int x, int y) {
        var point = new POINT { X = x, Y = y };
        var hit = WindowFromPoint(point);
        if (hit == IntPtr.Zero) return IntPtr.Zero;
        var root = GetAncestor(hit, 2);
        return root == IntPtr.Zero ? hit : root;
    }

    private static void MoveCursorSmoothly(int x, int y) {
        POINT start;
        if (!GetCursorPos(out start)) {
            if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed");
            return;
        }
        double distance = Math.Sqrt(Math.Pow(x - start.X, 2) + Math.Pow(y - start.Y, 2));
        int steps = Math.Max(8, Math.Min(24, (int)Math.Ceiling(distance / 40.0)));
        for (int i = 1; i <= steps; i++) {
            double t = i / (double)steps;
            double eased = t * t * (3.0 - (2.0 * t));
            int nextX = start.X + (int)Math.Round((x - start.X) * eased);
            int nextY = start.Y + (int)Math.Round((y - start.Y) * eased);
            if (!SetCursorPos(nextX, nextY)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed");
            Thread.Sleep(8);
        }
    }

    public static void ClickAt(int x, int y, uint downFlag, uint upFlag, int count) {
        MoveCursorSmoothly(x, y);
        int repeat = Math.Max(1, count);
        for (int i = 0; i < repeat; i++) {
            SendInputChecked(new[] { MouseInput(downFlag, 0), MouseInput(upFlag, 0) });
            Thread.Sleep(50);
        }
    }

    public static void DragTo(int fromX, int fromY, int toX, int toY) {
        MoveCursorSmoothly(fromX, fromY);
        SendInputChecked(new[] { MouseInput(0x0002, 0) });
        for (int i = 1; i <= 12; i++) {
            int x = fromX + ((toX - fromX) * i / 12);
            int y = fromY + ((toY - fromY) * i / 12);
            if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed");
            Thread.Sleep(16);
        }
        SendInputChecked(new[] { MouseInput(0x0004, 0) });
    }

    public static void WheelAt(int x, int y, int delta, bool horizontal) {
        MoveCursorSmoothly(x, y);
        SendInputChecked(new[] { MouseInput(horizontal ? 0x1000u : 0x0800u, unchecked((uint)delta)) });
    }

    public static void SendUnicodeText(string text) {
        var inputs = new List<INPUT>(text.Length * 2);
        foreach (char value in text) {
            inputs.Add(KeyboardInput(0, value, 0x0004));
            inputs.Add(KeyboardInput(0, value, 0x0004 | 0x0002));
        }
        if (inputs.Count > 0) SendInputChecked(inputs.ToArray());
    }

    public static void SendKeyChord(ushort[] modifiers, ushort key) {
        var inputs = new List<INPUT>();
        foreach (ushort modifier in modifiers) inputs.Add(KeyboardInput(modifier, 0, 0));
        inputs.Add(KeyboardInput(key, 0, 0));
        inputs.Add(KeyboardInput(key, 0, 0x0002));
        for (int i = modifiers.Length - 1; i >= 0; i--) inputs.Add(KeyboardInput(modifiers[i], 0, 0x0002));
        SendInputChecked(inputs.ToArray());
    }
}
"@

$addTypeFailure = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    try {
        Add-Type -TypeDefinition $win32Source -ErrorAction Stop
        $addTypeFailure = $null
        break
    } catch {
        $addTypeFailure = $_
        if ($attempt -lt 5 -and $_.FullyQualifiedErrorId -like "SOURCE_CODE_ERROR*") {
            Start-Sleep -Milliseconds (250 * $attempt)
            continue
        }
        break
    }
}
if ($null -ne $addTypeFailure) {
    throw $addTypeFailure
}

$script:DpiAwarenessMode = if ([OCUWin32]::EnablePerMonitorV2DpiAwareness()) { "per-monitor-v2" } else { "unavailable" }

$GW_OWNER = 4
$SW_RESTORE = 9
$PW_RENDERFULLCONTENT = 0x00000002

$WM_SETTEXT = 0x000C
$WM_MOUSEMOVE = 0x0200
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_RBUTTONDOWN = 0x0204
$WM_RBUTTONUP = 0x0205
$WM_MBUTTONDOWN = 0x0207
$WM_MBUTTONUP = 0x0208
$WM_MOUSEWHEEL = 0x020A
$WM_MOUSEHWHEEL = 0x020E
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_CHAR = 0x0102
$EM_SETSEL = 0x00B1
$EM_REPLACESEL = 0x00C2

function Test-EnvFlagEnabled([string]$name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    $normalized = $value.Trim().ToLowerInvariant()
    return @("1", "true", "yes", "on") -contains $normalized
}

function Get-WindowGeneration($process, [IntPtr]$hwnd) {
    $startedTicks = 0L
    try { $startedTicks = $process.StartTime.ToUniversalTime().Ticks } catch {}
    return ("{0}-{1}-{2}" -f [int]$process.Id, $hwnd.ToInt64(), $startedTicks)
}

function New-WindowRecord($process, [IntPtr]$hwnd, [IntPtr]$foregroundHwnd) {
    $owner = [OCUWin32]::GetWindow($hwnd, $script:GW_OWNER)
    $started = ""
    try { $started = $process.StartTime.ToUniversalTime().ToString("o") } catch {}
    [pscustomobject]@{
        appId = [string]$process.ProcessName
        pid = [int]$process.Id
        hwnd = [string]$hwnd.ToInt64()
        title = [OCUWin32]::ReadWindowTitle($hwnd)
        generation = Get-WindowGeneration $process $hwnd
        ownerHwnd = if ($owner -eq [IntPtr]::Zero) { "" } else { [string]$owner.ToInt64() }
        # An owned window is not necessarily modal. Treat it as modal only
        # while its owner is disabled, which is the normal Win32 dialog state.
        isModal = $owner -ne [IntPtr]::Zero -and -not [OCUWin32]::IsWindowEnabled($owner)
        isForeground = $hwnd -eq $foregroundHwnd
        isMinimized = [OCUWin32]::IsIconic($hwnd)
        processStarted = $started
    }
}

function Get-WindowRecords([string]$appFilter = "") {
    $records = New-Object System.Collections.Generic.List[object]
    $foreground = [OCUWin32]::GetForegroundWindow()
    $normalizedFilter = ""
    if (-not [string]::IsNullOrWhiteSpace($appFilter)) {
        $normalizedFilter = $appFilter.Trim()
        if ($normalizedFilter.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
            $normalizedFilter = $normalizedFilter.Substring(0, $normalizedFilter.Length - 4)
        }
    }
    foreach ($hwnd in [OCUWin32]::EnumerateTopLevelWindows()) {
        $processId = [uint32]0
        [void][OCUWin32]::GetWindowThreadProcessId($hwnd, [ref]$processId)
        if ($processId -eq 0) { continue }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        $record = New-WindowRecord $process $hwnd $foreground
        if (-not [string]::IsNullOrWhiteSpace($normalizedFilter) -and $record.appId -ine $normalizedFilter) {
            continue
        }
        $records.Add($record)
    }
    return $records.ToArray()
}

function Get-BlockingModalWindows($window) {
    if ($null -eq $window -or [string]::IsNullOrWhiteSpace([string]$window.hwnd)) {
        return @()
    }
    $records = @(Get-WindowRecords)
    $owners = New-Object 'System.Collections.Generic.HashSet[string]'
    [void]$owners.Add([string]$window.hwnd)
    $blocking = New-Object System.Collections.Generic.List[object]
    for ($depth = 0; $depth -lt 8; $depth++) {
        $next = @($records | Where-Object { $_.isModal -and $owners.Contains([string]$_.ownerHwnd) -and -not $owners.Contains([string]$_.hwnd) })
        if ($next.Count -eq 0) { break }
        foreach ($candidate in $next) {
            $blocking.Add($candidate)
            [void]$owners.Add([string]$candidate.hwnd)
        }
    }
    return $blocking.ToArray()
}

function Format-WindowsText($records) {
    $items = @($records)
    if ($items.Count -eq 0) { return "" }
    $json = ConvertTo-Json -InputObject $items -Depth 8 -Compress
    if ($items.Count -eq 1 -and -not $json.StartsWith("[")) {
        return "[$json]"
    }
    return $json
}

function Resolve-WindowQuery([string]$app, [string]$title = "") {
    if ([string]::IsNullOrWhiteSpace($app)) { throw "Missing required argument: app" }
    $matches = @(Get-WindowRecords $app | Where-Object {
        [string]::IsNullOrWhiteSpace($title) -or $_.title.IndexOf($title, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($matches.Count -eq 0) {
        throw "window_not_found(app='$app', title='$title')"
    }
    if ($matches.Count -gt 1) {
        $candidates = Format-WindowsText $matches
        throw "ambiguous_window(app='$app', title='$title', candidates=$candidates)"
    }
    return $matches[0]
}

function Resolve-ProcessWindow($process) {
    $mainHandle = [IntPtr]$process.MainWindowHandle
    if ($mainHandle -ne [IntPtr]::Zero -and [OCUWin32]::IsWindow($mainHandle)) {
        $mainRecord = @(Get-WindowRecords | Where-Object { $_.pid -eq $process.Id -and $_.hwnd -eq [string]$mainHandle.ToInt64() })
        if ($mainRecord.Count -eq 1) {
            return $mainRecord[0]
        }
    }
    $matches = @(Get-WindowRecords | Where-Object { $_.pid -eq $process.Id })
    if ($matches.Count -eq 0) {
        throw "window_not_found(app='$($process.ProcessName)', pid=$($process.Id))"
    }
    if ($matches.Count -gt 1) {
        throw "ambiguous_window(app='$($process.ProcessName)', pid=$($process.Id), candidates=$(Format-WindowsText $matches))"
    }
    return $matches[0]
}

function Resolve-WindowRef($windowRef) {
    if ($null -eq $windowRef) { throw "invalid_window_ref(missing window)" }
    $expectedPid = [int]$windowRef.pid
    $expectedHwnd = [string]$windowRef.hwnd
    $expectedGeneration = [string]$windowRef.generation
    if ($expectedPid -le 0 -or [string]::IsNullOrWhiteSpace($expectedHwnd) -or [string]::IsNullOrWhiteSpace($expectedGeneration)) {
        throw "invalid_window_ref(appId, pid, hwnd, and generation are required)"
    }
    $matches = @(Get-WindowRecords | Where-Object { $_.pid -eq $expectedPid -and $_.hwnd -eq $expectedHwnd })
    if ($matches.Count -ne 1) {
        throw "stale_window(pid=$expectedPid, hwnd=$expectedHwnd)"
    }
    $current = $matches[0]
    if ($current.generation -ne $expectedGeneration -or (-not [string]::IsNullOrWhiteSpace($windowRef.appId) -and $current.appId -ine [string]$windowRef.appId)) {
        throw "stale_window(pid=$expectedPid, hwnd=$expectedHwnd, generation changed)"
    }
    return $current
}

function Launch-AppWindow([string]$app) {
    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH")) {
        throw "app_launch_disabled(set OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH=1 to enable launch_app)"
    }
    try {
        $started = Start-Process -FilePath $app -PassThru
    } catch {
        throw "app_launch_failed(app='$app'): $($_.Exception.Message)"
    }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        $matches = @(Get-WindowRecords | Where-Object { $_.pid -eq $started.Id })
        if ($matches.Count -eq 1) { return $matches[0] }
        if ($matches.Count -gt 1) {
            throw "ambiguous_window(app='$app', candidates=$(Format-WindowsText $matches))"
        }
    }
    throw "window_not_found_after_launch(app='$app', pid=$($started.Id))"
}

function Activate-Window($windowRef) {
    $window = Resolve-WindowRef $windowRef
    $blockingModalWindows = @(Get-BlockingModalWindows $window)
    if ($blockingModalWindows.Count -gt 0) {
        throw "modal_window_required(owner=$($window.hwnd), candidates=$(Format-WindowsText $blockingModalWindows))"
    }
    $hwndValue = 0L
    if (-not [long]::TryParse($window.hwnd, [ref]$hwndValue)) {
        throw "invalid_window_ref(hwnd must be a decimal string)"
    }
    $hwnd = [IntPtr]$hwndValue
    if (-not [OCUWin32]::IsWindow($hwnd)) {
        throw "stale_window(pid=$($window.pid), hwnd=$($window.hwnd))"
    }

    $targetProcessId = [uint32]0
    $targetThread = [OCUWin32]::GetWindowThreadProcessId($hwnd, [ref]$targetProcessId)
    $currentThread = [OCUWin32]::GetCurrentThreadId()
    $foregroundBefore = [OCUWin32]::GetForegroundWindow()
    $foregroundProcessId = [uint32]0
    $foregroundThread = if ($foregroundBefore -eq [IntPtr]::Zero) { 0 } else { [OCUWin32]::GetWindowThreadProcessId($foregroundBefore, [ref]$foregroundProcessId) }
    $attachedCurrent = $false
    $attachedForeground = $false
    try {
        if ($currentThread -ne $targetThread) {
            $attachedCurrent = [OCUWin32]::AttachThreadInput($currentThread, $targetThread, $true)
        }
        if ($foregroundThread -ne 0 -and $foregroundThread -ne $targetThread -and $foregroundThread -ne $currentThread) {
            $attachedForeground = [OCUWin32]::AttachThreadInput($foregroundThread, $targetThread, $true)
        }
        if ([OCUWin32]::IsIconic($hwnd)) { [void][OCUWin32]::ShowWindowAsync($hwnd, $script:SW_RESTORE) }
        [void][OCUWin32]::BringWindowToTop($hwnd)
        [void][OCUWin32]::SetForegroundWindow($hwnd)
        if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS") {
            try { ([Windows.Automation.AutomationElement]::FromHandle($hwnd)).SetFocus() } catch {}
        }
    } finally {
        if ($attachedForeground) { [void][OCUWin32]::AttachThreadInput($foregroundThread, $targetThread, $false) }
        if ($attachedCurrent) { [void][OCUWin32]::AttachThreadInput($currentThread, $targetThread, $false) }
    }

    for ($i = 0; $i -lt 10; $i++) {
        if ([OCUWin32]::GetForegroundWindow() -eq $hwnd) {
            return Resolve-WindowRef $window
        }
        Start-Sleep -Milliseconds 50
    }
    $actual = [OCUWin32]::GetForegroundWindow().ToInt64()
    throw "foreground_not_acquired(target=$($window.hwnd), actual=$actual)"
}

function New-Frame($x, $y, $width, $height) {
    if ($width -lt 0 -or $height -lt 0) {
        return $null
    }
    [pscustomobject]@{
        x = [double]$x
        y = [double]$y
        width = [double]$width
        height = [double]$height
    }
}

function ConvertTo-LParam([int]$x, [int]$y) {
    $packed = (($y -band 0xffff) -shl 16) -bor ($x -band 0xffff)
    [IntPtr]$packed
}

function ConvertTo-WheelWParam([int]$delta) {
    $packed = (($delta -band 0xffff) -shl 16)
    [IntPtr]$packed
}

function Get-WindowRectFrame([IntPtr]$hwnd) {
    $rect = New-Object OCUWin32+RECT
    if ([OCUWin32]::GetWindowRect($hwnd, [ref]$rect)) {
        return New-Frame $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
    }
    return $null
}

function Get-ElementFrame($element, $windowBounds) {
    try {
        $rect = $element.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
            return $null
        }
        if ($null -ne $windowBounds) {
            return New-Frame ($rect.X - $windowBounds.x) ($rect.Y - $windowBounds.y) $rect.Width $rect.Height
        }
        return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
    } catch {
        return $null
    }
}

function Get-ScreenPoint($localFrame, $windowBounds) {
    if ($null -eq $localFrame -or $null -eq $windowBounds) {
        return $null
    }
    [pscustomobject]@{
        x = [int][math]::Round($windowBounds.x + $localFrame.x + ($localFrame.width / 2))
        y = [int][math]::Round($windowBounds.y + $localFrame.y + ($localFrame.height / 2))
    }
}

function Assert-WindowBoundsMatch($expected, $actual) {
    if ($null -eq $expected -or $null -eq $actual) {
        throw "stale_screenshot(window_bounds_unavailable)"
    }
    foreach ($name in @("x", "y", "width", "height")) {
        if ([math]::Abs([double]$expected.$name - [double]$actual.$name) -gt 1.0) {
            throw "stale_screenshot(window_bounds_changed expected=$($expected | ConvertTo-Json -Compress) actual=$($actual | ConvertTo-Json -Compress))"
        }
    }
}

function Convert-ScreenshotPoint([double]$x, [double]$y, $windowBounds, $capture, [string]$label) {
    if ($null -eq $windowBounds -or $null -eq $capture -or [int]$capture.width -le 0 -or [int]$capture.height -le 0) {
        throw "coordinate_mapping_unavailable($label)"
    }
    $captureWidth = [double]$capture.width
    $captureHeight = [double]$capture.height
    if ($x -lt 0 -or $y -lt 0 -or $x -ge $captureWidth -or $y -ge $captureHeight) {
        throw "coordinate_out_of_bounds($label x=$x y=$y capture=${captureWidth}x${captureHeight})"
    }
    return [pscustomobject]@{
        x = [int][math]::Round([double]$windowBounds.x + ($x * [double]$windowBounds.width / $captureWidth))
        y = [int][math]::Round([double]$windowBounds.y + ($y * [double]$windowBounds.height / $captureHeight))
    }
}

function Test-CoordinateMappingContract {
    $negativeBounds = [pscustomobject]@{ x = -1920; y = -200; width = 1920; height = 1080 }
    $nativeCapture = [pscustomobject]@{ width = 1920; height = 1080 }
    $topLeft = Convert-ScreenshotPoint 0 0 $negativeBounds $nativeCapture "negative.topLeft"
    $bottomRight = Convert-ScreenshotPoint 1919 1079 $negativeBounds $nativeCapture "negative.bottomRight"
    $scaledBounds = [pscustomobject]@{ x = -2560; y = 144; width = 2560; height = 1440 }
    $scaledCapture = [pscustomobject]@{ width = 1280; height = 720 }
    $scaledCenter = Convert-ScreenshotPoint 640 360 $scaledBounds $scaledCapture "mixedDpi.center"
    if ($topLeft.x -ne -1920 -or $topLeft.y -ne -200) {
        throw "coordinate_self_test_failed(negative_top_left actual=$($topLeft | ConvertTo-Json -Compress))"
    }
    if ($bottomRight.x -ne -1 -or $bottomRight.y -ne 879) {
        throw "coordinate_self_test_failed(negative_bottom_right actual=$($bottomRight | ConvertTo-Json -Compress))"
    }
    if ($scaledCenter.x -ne -1280 -or $scaledCenter.y -ne 864) {
        throw "coordinate_self_test_failed(mixed_dpi_center actual=$($scaledCenter | ConvertTo-Json -Compress))"
    }
    $outOfBoundsRejected = $false
    try {
        [void](Convert-ScreenshotPoint -1 0 $negativeBounds $nativeCapture "negative.invalid")
    } catch {
        $outOfBoundsRejected = $_.Exception.Message -like "coordinate_out_of_bounds*"
    }
    if (-not $outOfBoundsRejected) {
        throw "coordinate_self_test_failed(out_of_bounds_not_rejected)"
    }
    return [pscustomobject]@{
        status = "passed"
        coordinateSpace = "physical-screen-pixels"
        negativeTopLeft = $topLeft
        negativeBottomRight = $bottomRight
        mixedDpiCenter = $scaledCenter
        outOfBoundsRejected = $true
    }
}

function Send-MouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count) {
    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$point)
    $lParam = ConvertTo-LParam $point.X $point.Y

    $down = $WM_LBUTTONDOWN
    $up = $WM_LBUTTONUP
    $downFlag = 0x0001
    if ($button -eq "right") {
        $down = $WM_RBUTTONDOWN
        $up = $WM_RBUTTONUP
        $downFlag = 0x0002
    } elseif ($button -eq "middle") {
        $down = $WM_MBUTTONDOWN
        $up = $WM_MBUTTONUP
        $downFlag = 0x0010
    }

    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $lParam)
        [void][OCUWin32]::PostMessage($hwnd, $down, [IntPtr]$downFlag, $lParam)
        Start-Sleep -Milliseconds 35
        [void][OCUWin32]::PostMessage($hwnd, $up, [IntPtr]::Zero, $lParam)
        Start-Sleep -Milliseconds 50
    }
}

function Send-Drag([IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY) {
    $start = New-Object OCUWin32+POINT
    $start.X = $fromX
    $start.Y = $fromY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$start)
    $end = New-Object OCUWin32+POINT
    $end.X = $toX
    $end.Y = $toY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$end)

    $steps = 12
    $startParam = ConvertTo-LParam $start.X $start.Y
    [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $startParam)
    [void][OCUWin32]::PostMessage($hwnd, $WM_LBUTTONDOWN, [IntPtr]1, $startParam)
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int][math]::Round($start.X + (($end.X - $start.X) * $i / $steps))
        $y = [int][math]::Round($start.Y + (($end.Y - $start.Y) * $i / $steps))
        [void][OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]1, (ConvertTo-LParam $x $y))
        Start-Sleep -Milliseconds 20
    }
    [void][OCUWin32]::PostMessage($hwnd, $WM_LBUTTONUP, [IntPtr]::Zero, (ConvertTo-LParam $end.X $end.Y))
}

function Send-Scroll([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$direction, [double]$pages) {
    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    [void][OCUWin32]::ScreenToClient($hwnd, [ref]$point)
    $lParam = ConvertTo-LParam $point.X $point.Y
    $delta = [int][math]::Round(120 * $pages)
    $message = $WM_MOUSEWHEEL
    if ($direction -eq "down" -or $direction -eq "right") {
        $delta = -1 * $delta
    }
    if ($direction -eq "left" -or $direction -eq "right") {
        $message = $WM_MOUSEHWHEEL
    }
    [void][OCUWin32]::PostMessage($hwnd, $message, (ConvertTo-WheelWParam $delta), $lParam)
}

function Send-Text([IntPtr]$hwnd, [string]$text) {
    foreach ($char in $text.ToCharArray()) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_CHAR, [IntPtr][int][char]$char, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 8
    }
}

function Send-TextToEditHandle([IntPtr]$hwnd, [string]$text, $element) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return $false
    }

    try {
        [void][OCUWin32]::SendMessage($hwnd, $EM_SETSEL, [IntPtr](-1), [IntPtr](-1))
        [void][OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL, [IntPtr]1, $text)
        return $true
    } catch {
    }

    try {
        $current = ""
        if ($null -ne $element) {
            $current = Get-ElementValue $element
        }
        [void][OCUWin32]::SendMessage($hwnd, $WM_SETTEXT, [IntPtr]::Zero, ($current + $text))
        return $true
    } catch {
        return $false
    }
}

function Get-VirtualKey([string]$key) {
    $normalized = $key.ToLowerInvariant()
    $map = @{
        "return" = 0x0D; "enter" = 0x0D; "tab" = 0x09; "escape" = 0x1B; "esc" = 0x1B
        "backspace" = 0x08; "back_space" = 0x08; "delete" = 0x2E; "space" = 0x20
        "left" = 0x25; "up" = 0x26; "right" = 0x27; "down" = 0x28
        "home" = 0x24; "end" = 0x23; "page_up" = 0x21; "prior" = 0x21; "page_down" = 0x22; "next" = 0x22
    }
    if ($map.ContainsKey($normalized)) {
        return $map[$normalized]
    }
    if ($normalized -match "^f([1-9]|1[0-2])$") {
        return 0x70 + [int]$Matches[1] - 1
    }
    if ($normalized -match "^kp_([0-9])$") {
        return 0x60 + [int]$Matches[1]
    }
    if ($normalized.Length -eq 1) {
        $code = [int][char]$normalized.ToUpperInvariant()[0]
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A)) {
            return $code
        }
    }
    throw "Unsupported key: $key"
}

function Send-Key([IntPtr]$hwnd, [string]$key) {
    $parts = $key -split "\+"
    $main = $parts[$parts.Length - 1]
    $modifiers = @()
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            "ctrl" { $modifiers += 0x11 }
            "control" { $modifiers += 0x11 }
            "shift" { $modifiers += 0x10 }
            "alt" { $modifiers += 0x12 }
            "super" { $modifiers += 0x5B }
            "win" { $modifiers += 0x5B }
            "cmd" { $modifiers += 0x5B }
        }
    }
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$modifier, [IntPtr]::Zero)
    }
    $vk = Get-VirtualKey $main
    [void][OCUWin32]::PostMessage($hwnd, $WM_KEYDOWN, [IntPtr]$vk, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 25
    [void][OCUWin32]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$vk, [IntPtr]::Zero)
    [array]::Reverse($modifiers)
    foreach ($modifier in $modifiers) {
        [void][OCUWin32]::PostMessage($hwnd, $WM_KEYUP, [IntPtr]$modifier, [IntPtr]::Zero)
    }
}

function Assert-ForegroundWindow([IntPtr]$hwnd, [int]$allowedProcessId = 0) {
    $foreground = [OCUWin32]::GetForegroundWindow()
    if ($foreground -ne $hwnd) {
        if ($allowedProcessId -gt 0 -and $foreground -ne [IntPtr]::Zero) {
            $foregroundProcessId = [uint32]0
            [void][OCUWin32]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
            if ([int]$foregroundProcessId -eq $allowedProcessId) {
                return
            }
        }
        throw "foreground_not_acquired(target=$($hwnd.ToInt64()), actual=$($foreground.ToInt64()))"
    }
}

function Assert-PointTargetsWindow([IntPtr]$hwnd, [int]$screenX, [int]$screenY) {
    $rootAtPoint = [OCUWin32]::RootWindowAtPoint($screenX, $screenY)
    if ($rootAtPoint -ne $hwnd) {
        throw "occluded_by_non_target(target=$($hwnd.ToInt64()), actual=$($rootAtPoint.ToInt64()), x=$screenX, y=$screenY)"
    }
}

function Send-ForegroundMouseClick([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count) {
    Assert-ForegroundWindow $hwnd
    Assert-PointTargetsWindow $hwnd $screenX $screenY
    $down = [uint32]0x0002
    $up = [uint32]0x0004
    if ($button -eq "right") {
        $down = [uint32]0x0008
        $up = [uint32]0x0010
    } elseif ($button -eq "middle") {
        $down = [uint32]0x0020
        $up = [uint32]0x0040
    }
    [OCUWin32]::ClickAt($screenX, $screenY, $down, $up, [math]::Max(1, $count))
}

function Send-ForegroundDrag([IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY) {
    Assert-ForegroundWindow $hwnd
    Assert-PointTargetsWindow $hwnd $fromX $fromY
    Assert-PointTargetsWindow $hwnd $toX $toY
    [OCUWin32]::DragTo($fromX, $fromY, $toX, $toY)
}

function Send-ForegroundScroll([IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$direction, [double]$pages) {
    Assert-ForegroundWindow $hwnd
    Assert-PointTargetsWindow $hwnd $screenX $screenY
    $delta = [int][math]::Round(120 * $pages)
    if ($direction -eq "down" -or $direction -eq "right") { $delta = -1 * $delta }
    [OCUWin32]::WheelAt($screenX, $screenY, $delta, ($direction -eq "left" -or $direction -eq "right"))
}

function Send-ForegroundText([IntPtr]$hwnd, [int]$processId, [string]$text) {
    Assert-ForegroundWindow $hwnd $processId
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused -or $focused.Current.ProcessId -ne $processId) {
            throw "focused_element_not_in_target(pid=$processId)"
        }
    } catch {
        if ($_.Exception.Message -like "focused_element_not_in_target*") { throw }
        throw "focused_element_unknown(pid=$processId)"
    }
    [OCUWin32]::SendUnicodeText($text)
}

function Send-ForegroundKey([IntPtr]$hwnd, [string]$key, [int]$allowedProcessId = 0) {
    Assert-ForegroundWindow $hwnd $allowedProcessId
    $parts = $key -split "\+"
    $main = $parts[$parts.Length - 1]
    $modifiers = New-Object System.Collections.Generic.List[uint16]
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            "ctrl" { $modifiers.Add([uint16]0x11) }
            "control" { $modifiers.Add([uint16]0x11) }
            "shift" { $modifiers.Add([uint16]0x10) }
            "alt" { $modifiers.Add([uint16]0x12) }
            "super" { $modifiers.Add([uint16]0x5B) }
            "win" { $modifiers.Add([uint16]0x5B) }
            "cmd" { $modifiers.Add([uint16]0x5B) }
            default { throw "Unsupported modifier: $($parts[$i])" }
        }
    }
    [OCUWin32]::SendKeyChord($modifiers.ToArray(), [uint16](Get-VirtualKey $main))
}

function Resolve-App([string]$query) {
    $normalized = $query.Trim()
    $processQuery = $normalized
    if ($processQuery.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $processQuery = $processQuery.Substring(0, $processQuery.Length - 4)
    }
    $processes = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })
    $pidValue = 0
    if ([int]::TryParse($normalized, [ref]$pidValue)) {
        $match = $processes | Where-Object { $_.Id -eq $pidValue } | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }

    $match = $processes | Where-Object {
        $_.ProcessName -ieq $processQuery -or
        "$($_.ProcessName).exe" -ieq $normalized -or
        $_.MainWindowTitle -ieq $normalized -or
        $_.MainWindowTitle -ilike "*$normalized*"
    } | Select-Object -First 1
    if ($null -ne $match) {
        return $match
    }

    if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
        try {
            $started = Start-Process -FilePath $normalized -PassThru
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 250
                $candidate = Get-Process -Id $started.Id -ErrorAction SilentlyContinue
                if ($null -ne $candidate -and $candidate.MainWindowHandle -ne 0) {
                    return $candidate
                }
            }
        } catch {
        }
    }

    throw "appNotFound(`"$query`")"
}

function Get-MainElement($process, [IntPtr]$hwnd = [IntPtr]::Zero) {
    if ($hwnd -ne [IntPtr]::Zero) {
        return [Windows.Automation.AutomationElement]::FromHandle($hwnd)
    }
    if ($process.MainWindowHandle -ne 0) {
        return [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    }
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $process.Id
    $children = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    if ($children.Count -gt 0) {
        return $children.Item(0)
    }
    throw "No top-level UI Automation window is available for $($process.ProcessName). Run the Windows runtime in the signed-in desktop session."
}

function Get-WindowBounds([IntPtr]$hwnd, $element) {
    if ($hwnd -ne [IntPtr]::Zero) {
        $fromWin32 = Get-WindowRectFrame $hwnd
        if ($null -ne $fromWin32) {
            return $fromWin32
        }
    }
    try {
        $rect = $element.Current.BoundingRectangle
        if (-not $rect.IsEmpty -and $rect.Width -gt 0 -and $rect.Height -gt 0) {
            return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
        }
    } catch {
    }
    return $null
}

function Get-PatternNames($element) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $element.GetSupportedPatterns()) {
        $programmatic = $pattern.ProgrammaticName
        if ($programmatic -like "InvokePatternIdentifiers.Pattern") { $names.Add("Invoke") }
        elseif ($programmatic -like "TogglePatternIdentifiers.Pattern") { $names.Add("Toggle") }
        elseif ($programmatic -like "SelectionItemPatternIdentifiers.Pattern") { $names.Add("Select") }
        elseif ($programmatic -like "ExpandCollapsePatternIdentifiers.Pattern") {
            try {
                $state = $element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState
                if ($state -eq [Windows.Automation.ExpandCollapseState]::Collapsed) { $names.Add("Expand") }
                elseif ($state -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $names.Add("Collapse") }
            } catch {
                $names.Add("Expand")
                $names.Add("Collapse")
            }
        }
        elseif ($programmatic -like "ScrollItemPatternIdentifiers.Pattern") { $names.Add("ScrollIntoView") }
        elseif ($programmatic -like "ScrollPatternIdentifiers.Pattern") { $names.Add("Scroll") }
        elseif ($programmatic -like "ValuePatternIdentifiers.Pattern") { $names.Add("SetValue") }
    }
    if ((Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS") -and (Get-ElementBool $element "IsKeyboardFocusable")) {
        $names.Add("SetFocus")
    }
    if ($names.Count -gt 0) {
        return @($names | Select-Object -Unique)
    }
    return @()
}

function Get-ElementString($element, [string]$propertyName) {
    try {
        $value = $element.Current.$propertyName
        if ($null -eq $value) {
            return ""
        }
        return [string]$value
    } catch {
        return ""
    }
}

function Get-ElementInt64($element, [string]$propertyName) {
    try {
        return [int64]$element.Current.$propertyName
    } catch {
        return 0
    }
}

function Get-ElementBool($element, [string]$propertyName) {
    try {
        return [bool]$element.Current.$propertyName
    } catch {
        return $false
    }
}

function Get-ElementControlTypeName($element) {
    try {
        $controlType = $element.Current.ControlType
        if ($null -eq $controlType) {
            return ""
        }
        return [string]$controlType.ProgrammaticName
    } catch {
        return ""
    }
}

function Resolve-TextLimit($Value) {
    if ($null -eq $Value) {
        return $script:DefaultTextLimit
    }
    if ($Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq "max") {
        return $null
    }
    if ($Value -is [bool]) {
        return $script:DefaultTextLimit
    }
    try {
        $integer = [int]$Value
        if ($integer -gt 0) {
            return $integer
        }
    } catch {
    }
    return $script:DefaultTextLimit
}

function Limit-Text([string]$Text, $TextLimit = $script:DefaultTextLimit) {
    if ($null -eq $Text) {
        return ""
    }
    if ($null -eq $TextLimit) {
        return $Text
    }
    $effectiveTextLimit = [int]$TextLimit
    if ($Text.Length -gt $effectiveTextLimit) {
        return $Text.Substring(0, $effectiveTextLimit) + "..."
    }
    return $Text
}

function Get-ElementValue($element, $TextLimit = $script:DefaultTextLimit) {
    if (Get-ElementBool $element "IsPassword") {
        return ""
    }
    try {
        $valuePattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $value = $valuePattern.Current.Value
        if ($null -eq $value) {
            return ""
        }
        $text = [string]$value
        return Limit-Text $text $TextLimit
    } catch {
        return ""
    }
}

function Get-ElementRecord($element, [int]$index, $windowBounds, $TextLimit = $script:DefaultTextLimit) {
    $frame = Get-ElementFrame $element $windowBounds
    $runtimeId = @()
    try { $runtimeId = @($element.GetRuntimeId()) } catch {}
    $isSelected = $false
    try {
        $selection = $element.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
        $isSelected = [bool]$selection.Current.IsSelected
    } catch {
    }
    [pscustomobject]@{
        index = $index
        runtimeId = $runtimeId
        automationId = Get-ElementString $element "AutomationId"
        name = Limit-Text (Get-ElementString $element "Name") $TextLimit
        controlType = Get-ElementControlTypeName $element
        localizedControlType = Get-ElementString $element "LocalizedControlType"
        className = Get-ElementString $element "ClassName"
        value = Get-ElementValue $element $TextLimit
        nativeWindowHandle = Get-ElementInt64 $element "NativeWindowHandle"
        frame = $frame
        actions = @(Get-PatternNames $element)
        isEnabled = Get-ElementBool $element "IsEnabled"
        isOffscreen = Get-ElementBool $element "IsOffscreen"
        isKeyboardFocusable = Get-ElementBool $element "IsKeyboardFocusable"
        hasKeyboardFocus = Get-ElementBool $element "HasKeyboardFocus"
        isSelected = $isSelected
        isPassword = Get-ElementBool $element "IsPassword"
    }
}

function Get-ElementTitle($record) {
    if (-not [string]::IsNullOrWhiteSpace($record.name)) {
        return $record.name
    }
    if (-not [string]::IsNullOrWhiteSpace($record.automationId)) {
        return "ID: $($record.automationId)"
    }
    return ""
}

function Render-Tree($element, $windowBounds, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth) {
    $records = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $nextIndex = 0
    $effectiveMaxTreeNodes = if ($MaxTreeNodes -gt 0) { $MaxTreeNodes } else { $script:AccessibilityTreeMaxNodeCount }
    $effectiveMaxTreeDepth = if ($MaxTreeDepth -gt 0) { $MaxTreeDepth } else { $script:AccessibilityTreeMaxDepth }

    function Visit($node, [int]$depth) {
        if ($script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth) {
            return
        }
        $runtime = ""
        try { $runtime = (@($node.GetRuntimeId()) -join ".") } catch { $runtime = [guid]::NewGuid().ToString() }
        if (-not $script:visited.Add($runtime)) {
            return
        }

        $index = $script:nextIndex
        $script:nextIndex++
        $record = Get-ElementRecord $node $index $script:windowBounds $TextLimit
        $script:records.Add($record)

        $role = $record.localizedControlType
        if ([string]::IsNullOrWhiteSpace($role)) {
            $role = $record.controlType
        }
        $title = Get-ElementTitle $record
        $actionsSegment = ""
        if ($record.actions.Count -gt 0) {
            $actionsSegment = " Secondary Actions: " + ($record.actions -join ", ")
        }
        $valueSegment = ""
        if (-not [string]::IsNullOrWhiteSpace($record.value) -and $record.value -ne $title) {
            $safeValue = (($record.value -replace "`r", "\\r") -replace "`n", "\\n")
            $valueSegment = " Value: $safeValue"
        }
        $frameSegment = ""
        if ($null -ne $record.frame) {
            $frameSegment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}" -f [int][math]::Round($record.frame.x), [int][math]::Round($record.frame.y), [int][math]::Round($record.frame.width), [int][math]::Round($record.frame.height)
        }
        $script:lines.Add(("`t" * ($depth + 1)) + "$index $role $title$valueSegment$actionsSegment$frameSegment")

        try {
            $children = $node.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
            for ($i = 0; $i -lt $children.Count; $i++) {
                Visit $children.Item($i) ($depth + 1)
            }
        } catch {
        }
    }

    $script:records = $records
    $script:lines = $lines
    $script:visited = $visited
    $script:nextIndex = $nextIndex
    $script:windowBounds = $windowBounds
    $script:MaxTreeNodes = $effectiveMaxTreeNodes
    $script:MaxTreeDepth = $effectiveMaxTreeDepth
    Visit $element 0

    [pscustomobject]@{
        records = $records.ToArray()
        lines = $lines.ToArray()
    }
}

function Convert-BitmapToPngBase64($bitmap) {
    $stream = New-Object System.IO.MemoryStream
    try {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return [Convert]::ToBase64String($stream.ToArray())
    } finally {
        $stream.Dispose()
    }
}

function Test-BitmapHasVisualContent($bitmap) {
    $reference = $null
    for ($row = 0; $row -lt 12; $row++) {
        $y = [int][math]::Min($bitmap.Height - 1, [math]::Floor(($row + 0.5) * $bitmap.Height / 12.0))
        for ($column = 0; $column -lt 12; $column++) {
            $x = [int][math]::Min($bitmap.Width - 1, [math]::Floor(($column + 0.5) * $bitmap.Width / 12.0))
            $value = $bitmap.GetPixel($x, $y).ToArgb()
            if ($null -eq $reference) {
                $reference = $value
            } elseif ($value -ne $reference) {
                return $true
            }
        }
    }
    return $false
}

function New-CaptureDescriptor(
    [string]$method,
    $bounds,
    [int]$width,
    [int]$height,
    [bool]$occlusionIndependent,
    [bool]$diagnosticFallback,
    [string]$warning,
    [IntPtr]$hwnd
) {
    $windowDpi = 96
    $dpi = 96
    try {
        $reportedWindowDpi = [int][OCUWin32]::GetDpiForWindow($hwnd)
        if ($reportedWindowDpi -gt 0) { $windowDpi = $reportedWindowDpi }
        $reportedDpi = [int][OCUWin32]::GetEffectiveMonitorDpi($hwnd)
        if ($reportedDpi -gt 0) { $dpi = $reportedDpi }
    } catch {
    }
    $originX = if ($null -eq $bounds) { 0 } else { [double]$bounds.x }
    $originY = if ($null -eq $bounds) { 0 } else { [double]$bounds.y }
    $virtualScreen = New-Frame ([OCUWin32]::GetSystemMetrics(76)) ([OCUWin32]::GetSystemMetrics(77)) ([OCUWin32]::GetSystemMetrics(78)) ([OCUWin32]::GetSystemMetrics(79))
    return [pscustomobject]@{
        method = $method
        originX = $originX
        originY = $originY
        width = $width
        height = $height
        occlusionIndependent = $occlusionIndependent
        diagnosticFallback = $diagnosticFallback
        warning = $warning
        dpi = $dpi
        windowDpi = $windowDpi
        scaleFactor = [double]$dpi / 96.0
        coordinateSpace = "physical-screen-pixels"
        dpiAwareness = $script:DpiAwarenessMode
        virtualScreen = $virtualScreen
    }
}

function Capture-WindowsGraphicsPng([IntPtr]$hwnd, $bounds) {
    if (-not [OCUWindowsGraphicsCapture]::IsSupported()) {
        throw "Windows.Graphics.Capture is not supported by this Windows build"
    }
    $result = [OCUWindowsGraphicsCapture]::CaptureWindow($hwnd.ToInt64(), 3000)
    if ($null -eq $result -or $null -eq $result.PngBytes -or $result.PngBytes.Length -eq 0) {
        throw "Windows.Graphics.Capture returned an empty PNG"
    }
    return [pscustomobject]@{
        pngBase64 = [Convert]::ToBase64String($result.PngBytes)
        descriptor = New-CaptureDescriptor "windows-graphics-capture" $bounds ([int]$result.Width) ([int]$result.Height) $true $false "" $hwnd
    }
}

function Add-CaptureWarning([string]$existing, [string]$next) {
    if ([string]::IsNullOrWhiteSpace($existing)) {
        return $next
    }
    return "$existing; $next"
}

function Get-Base64Sha256([string]$base64) {
    if ([string]::IsNullOrWhiteSpace($base64)) { return "" }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Convert]::FromBase64String($base64)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha256.Dispose()
    }
}

function Capture-WindowPng([IntPtr]$hwnd, $bounds) {
    if ($null -eq $bounds -or $bounds.width -le 0 -or $bounds.height -le 0) {
        return [pscustomobject]@{
            pngBase64 = $null
            descriptor = New-CaptureDescriptor "unavailable" $null 0 0 $false $false "invalid_window_bounds" $hwnd
        }
    }
    $width = [int][math]::Round($bounds.width)
    $height = [int][math]::Round($bounds.height)
    $warning = ""

    if ($hwnd -ne [IntPtr]::Zero -and [OCUWin32]::IsIconic($hwnd)) {
        return [pscustomobject]@{
            pngBase64 = $null
            descriptor = New-CaptureDescriptor "unavailable" $bounds $width $height $false $false "window_minimized_activate_window_required" $hwnd
        }
    }

    try {
        $graphicsCapture = Capture-WindowsGraphicsPng $hwnd $bounds
        if ($null -ne $graphicsCapture -and -not [string]::IsNullOrWhiteSpace($graphicsCapture.pngBase64)) {
            return $graphicsCapture
        }
        $warning = Add-CaptureWarning $warning "windows_graphics_capture_empty"
    } catch {
        $warning = Add-CaptureWarning $warning "windows_graphics_capture_failed($($_.Exception.Message))"
    }

    if ($hwnd -ne [IntPtr]::Zero) {
        $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $hdc = [IntPtr]::Zero
        try {
            $hdc = $graphics.GetHdc()
            if ([OCUWin32]::PrintWindow($hwnd, $hdc, [uint32]0)) {
                if (Test-BitmapHasVisualContent $bitmap) {
                    return [pscustomobject]@{
                        pngBase64 = Convert-BitmapToPngBase64 $bitmap
                        descriptor = New-CaptureDescriptor "print-window" $bounds $width $height $true $false "" $hwnd
                    }
                }
                $warning = Add-CaptureWarning $warning "print_window_blank(flags=0; PW_RENDERFULLCONTENT unavailable for this surface)"
            } else {
                $warning = Add-CaptureWarning $warning "print_window_failed(win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
            }
        } catch {
            $warning = Add-CaptureWarning $warning "print_window_failed($($_.Exception.Message))"
        } finally {
            if ($hdc -ne [IntPtr]::Zero) {
                $graphics.ReleaseHdc($hdc)
            }
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    try {
        $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen([int][math]::Round($bounds.x), [int][math]::Round($bounds.y), 0, 0, $bitmap.Size)
            return [pscustomobject]@{
                pngBase64 = Convert-BitmapToPngBase64 $bitmap
                descriptor = New-CaptureDescriptor "screen-copy-fallback" $bounds $width $height $false $true $warning $hwnd
            }
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    } catch {
        $fallbackError = $_.Exception.Message
        return [pscustomobject]@{
            pngBase64 = $null
            descriptor = New-CaptureDescriptor "unavailable" $bounds $width $height $false $true "$warning; screen_copy_failed($fallbackError)" $hwnd
        }
    }
}

function Get-FocusedSummary($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $role = $focused.Current.LocalizedControlType
            $name = Limit-Text $focused.Current.Name $TextLimit
            if ([string]::IsNullOrWhiteSpace($name)) {
                return $role
            }
            return "$role $name"
        }
    } catch {
    }
    return $null
}

function Get-SelectedText($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused -or $focused.Current.ProcessId -ne $processId) {
            return $null
        }
        $textPattern = $focused.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $selection = $textPattern.GetSelection()
        if ($selection.Count -gt 0) {
            $maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }
            return Limit-Text ($selection.Item(0).GetText($maxLength)) $TextLimit
        }
    } catch {
    }
    return $null
}

function Get-DocumentText($root, [int]$processId, $TextLimit = $script:DefaultTextLimit) {
    $candidates = New-Object System.Collections.Generic.List[object]
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $candidates.Add($focused)
        }
    } catch {
    }
    $candidates.Add($root)
    foreach ($controlType in @([Windows.Automation.ControlType]::Document, [Windows.Automation.ControlType]::Edit)) {
        try {
            $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ControlTypeProperty), $controlType
            $candidate = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
            if ($null -ne $candidate) {
                $candidates.Add($candidate)
            }
        } catch {
        }
    }
    foreach ($element in $candidates) {
        try {
            $textPattern = $element.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
            $maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }
            $text = [string]$textPattern.DocumentRange.GetText($maxLength)
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                return Limit-Text $text $TextLimit
            }
        } catch {
        }
    }
    return $null
}

function Get-FocusedElementRecord([int]$processId, $windowBounds, $renderedRecords, $TextLimit = $script:DefaultTextLimit) {
    $record = @($renderedRecords | Where-Object { $_.hasKeyboardFocus } | Select-Object -First 1)[0]
    if ($null -ne $record) {
        return $record
    }
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            return Get-ElementRecord $focused -1 $windowBounds $TextLimit
        }
    } catch {
    }
    return $null
}

function Build-Snapshot([string]$query, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth, $WindowRef = $null) {
    if ($null -ne $WindowRef) {
        $window = Resolve-WindowRef $WindowRef
        $process = Get-Process -Id $window.pid -ErrorAction Stop
        $hwnd = [IntPtr][long]$window.hwnd
        $element = Get-MainElement $process $hwnd
    } else {
        $process = Resolve-App $query
        $window = Resolve-ProcessWindow $process
        $hwnd = [IntPtr][long]$window.hwnd
        $element = Get-MainElement $process $hwnd
    }
    $bounds = Get-WindowBounds $hwnd $element
    $rendered = Render-Tree $element $bounds $TextLimit $MaxTreeNodes $MaxTreeDepth
    $focusedElement = Get-FocusedElementRecord $process.Id $bounds $rendered.records $TextLimit
    $selectedElements = @($rendered.records | Where-Object { $_.isSelected })
    $capture = Capture-WindowPng $hwnd $bounds
    $screenshotSha256 = Get-Base64Sha256 $capture.pngBase64
    $modalWindows = @(Get-BlockingModalWindows $window)
    $snapshotID = ("{0}:{1}" -f $window.generation, [DateTime]::UtcNow.Ticks)
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
        }
        window = $window
        windowClosed = $false
        observationId = $snapshotID
        screenshotId = $snapshotID
        windowTitle = Limit-Text $window.title $TextLimit
        windowBounds = $bounds
        modalWindows = $modalWindows
        capture = $capture.descriptor
        screenshotPngBase64 = $capture.pngBase64
        screenshotSha256 = $screenshotSha256
        treeLines = @($rendered.lines)
        focusedSummary = Get-FocusedSummary $process.Id $TextLimit
        focusedElement = $focusedElement
        selectedText = Get-SelectedText $process.Id $TextLimit
        selectedElements = $selectedElements
        documentText = Get-DocumentText $element $process.Id $TextLimit
        elements = @($rendered.records)
    }
}

function New-ClosedWindowSnapshot($process, $window) {
    $snapshotID = ("{0}:closed:{1}" -f $window.generation, [DateTime]::UtcNow.Ticks)
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
        }
        windowClosed = $true
        observationId = $snapshotID
        screenshotId = $snapshotID
        windowTitle = [string]$window.title
        modalWindows = @()
        treeLines = @()
        selectedElements = @()
        elements = @()
    }
}

function Get-OperationPropertyValue($operation, [string]$name) {
    $property = $operation.PSObject.Properties[$name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Resolve-ActionContext($operation) {
    $windowArgument = Get-OperationPropertyValue $operation "window"
    if ($null -ne $windowArgument) {
        $window = Activate-Window $windowArgument
        $process = Get-Process -Id $window.pid -ErrorAction Stop
    } else {
        $process = Resolve-App $operation.app
        $window = Resolve-ProcessWindow $process
    }
    $hwnd = [IntPtr][long]$window.hwnd
    $foreground = [OCUWin32]::GetForegroundWindow()
    if ($null -ne $windowArgument -and $foreground -ne $hwnd) {
        throw "foreground_not_acquired(target=$($window.hwnd), actual=$($foreground.ToInt64()))"
    }
    $root = Get-MainElement $process $hwnd
    $windowBounds = Get-WindowBounds $hwnd $root
    $element = Find-Element $root (Get-OperationPropertyValue $operation "element")
    [pscustomobject]@{
        process = $process
        window = $window
        hwnd = $hwnd
        root = $root
        windowBounds = $windowBounds
        element = $element
    }
}

function Test-MutatingTool([string]$toolName) {
    return @("click", "drag", "perform_secondary_action", "press_key", "scroll", "set_value", "type_text") -contains $toolName
}

function Test-ControlTool([string]$toolName) {
    return $toolName -eq "launch_app" -or $toolName -eq "activate_window" -or (Test-MutatingTool $toolName)
}

function Get-ActionLockTimeoutMilliseconds {
    $value = 5000
    $configured = [Environment]::GetEnvironmentVariable("OPEN_COMPUTER_USE_WINDOWS_ACTION_LOCK_TIMEOUT_MS")
    $parsed = 0
    if (-not [string]::IsNullOrWhiteSpace($configured) -and [int]::TryParse($configured, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 120000) {
        $value = $parsed
    }
    return $value
}

function Enter-ForegroundInputLock {
    $name = "Local\DSHDesktopOperator.ForegroundInput.v1"
    $mutex = New-Object System.Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne((Get-ActionLockTimeoutMilliseconds))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "action_locked(name=$name): another desktop operator is controlling foreground input"
        }
        return $mutex
    } catch {
        if (-not $acquired) { $mutex.Dispose() }
        throw
    }
}

function Exit-ForegroundInputLock($mutex) {
    if ($null -eq $mutex) { return }
    try {
        $mutex.ReleaseMutex()
    } catch {
    } finally {
        $mutex.Dispose()
    }
}

function Resolve-ActionFailureStatus([string]$message) {
    if (
        $message -like "stale_window*" -or
        $message -like "stale_screenshot*" -or
        $message -like "invalid_window_ref*" -or
        $message -like "foreground_not_acquired*" -or
        $message -like "modal_window_required*" -or
        $message -like "focus_not_acquired*" -or
        $message -like "focused_element_not_in_target*" -or
        $message -like "focused_element_unknown*" -or
        $message -like "action_locked*" -or
        $message -like "occluded_by_non_target*" -or
        $message -like "coordinate_mapping_unavailable*" -or
        $message -like "coordinate_out_of_bounds*" -or
        $message -like "unknown element_index*" -or
        $message -like "Missing required argument:*" -or
        $message -like "Cannot set a value*" -or
        $message -like "value_not_applied*" -or
        $message -like "click_method *" -or
        $message -like "Unsupported key:*"
    ) {
        return "rejected"
    }
    return "unknown"
}

function Find-SnapshotElement($snapshot, $targetRecord) {
    if ($null -eq $snapshot -or $null -eq $targetRecord) { return $null }
    foreach ($record in @($snapshot.elements)) {
        if (Same-RuntimeId @($record.runtimeId) @($targetRecord.runtimeId)) {
            return $record
        }
    }
    return $null
}

function Test-ExpectedPostcondition($expected, $operation, $snapshot, [IntPtr]$hwnd) {
    if ($null -eq $expected) { return $null }
    $type = ([string]$expected.type).Trim().ToLowerInvariant()
    $satisfied = $false
    $detail = ""
    $conditions = @()
    switch ($type) {
        "target_focused" {
            if ($null -eq $operation.element -or $null -eq $snapshot.focusedElement) {
                $detail = "target or focused element unavailable"
            } else {
                $satisfied = Same-RuntimeId @($snapshot.focusedElement.runtimeId) @($operation.element.runtimeId)
                $detail = if ($satisfied) { "target element has keyboard focus" } else { "focused element identity differs from target" }
            }
        }
        "target_value_equals" {
            $record = Find-SnapshotElement $snapshot $operation.element
            if ($null -eq $record) {
                $detail = "target element unavailable after action"
            } else {
                $actual = [string]$record.value
                $expectedValue = [string]$expected.value
                $satisfied = $actual -ceq $expectedValue
                $detail = if ($satisfied) { "target value matched" } else { "target value mismatch" }
            }
        }
        "text_contains" {
            $needle = [string]$expected.text
            $haystack = (@($snapshot.treeLines) + @([string]$snapshot.documentText, [string]$snapshot.selectedText, [string]$snapshot.focusedSummary)) -join "`n"
            $satisfied = $haystack.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            $detail = if ($satisfied) { "snapshot contains expected text" } else { "expected text not found in refreshed snapshot" }
        }
        "foreground_window" {
            $actual = [OCUWin32]::GetForegroundWindow()
            $satisfied = $actual -eq $hwnd
            $detail = if ($satisfied) { "target window is foreground" } else { "foreground hwnd=$($actual.ToInt64()) target=$($hwnd.ToInt64())" }
        }
        "screenshot_changed" {
            $before = [string](Get-OperationPropertyValue $operation "before_screenshot_sha256")
            $after = [string]$snapshot.screenshotSha256
            $satisfied = -not [string]::IsNullOrWhiteSpace($before) -and -not [string]::IsNullOrWhiteSpace($after) -and $before -ne $after
            $detail = if ($satisfied) { "screenshot content changed" } else { "screenshot content did not change or could not be compared" }
        }
        "window_closed" {
            $satisfied = [bool](Get-OperationPropertyValue $snapshot "windowClosed")
            $detail = if ($satisfied) { "target window closed" } else { "target window remains open" }
        }
        { $_ -eq "all" -or $_ -eq "any" } {
            foreach ($child in @($expected.conditions)) {
                $conditions += Test-ExpectedPostcondition $child $operation $snapshot $hwnd
            }
            if ($type -eq "all") {
                $satisfied = $conditions.Count -gt 0 -and @($conditions | Where-Object { -not $_.satisfied }).Count -eq 0
                $detail = if ($satisfied) { "all postconditions satisfied" } else { "one or more postconditions were not satisfied" }
            } else {
                $satisfied = @($conditions | Where-Object { $_.satisfied }).Count -gt 0
                $detail = if ($satisfied) { "at least one postcondition satisfied" } else { "no postconditions were satisfied" }
            }
        }
        default {
            $detail = "unsupported postcondition type"
        }
    }
    $result = [pscustomobject]@{
        type = $type
        satisfied = [bool]$satisfied
        detail = $detail
    }
    if ($conditions.Count -gt 0) {
        $result | Add-Member -NotePropertyName conditions -NotePropertyValue @($conditions) -Force
    }
    return $result
}

function List-Apps {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object ProcessName, Id)) {
        $title = $process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "untitled"
        }
        $lines.Add(("{0} -- {1} [running, pid={2}, window={3}]" -f $process.ProcessName, $process.ProcessName, $process.Id, $title))
    }
    return ($lines -join "`n")
}

function Same-RuntimeId($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.Count -eq 0 -or $left.Count -ne $right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $left.Count; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) {
            return $false
        }
    }
    return $true
}

function Set-ElementFocusVerified($element) {
    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
        return $false
    }
    if ($null -eq $element -or -not (Get-ElementBool $element "IsKeyboardFocusable")) {
        return $false
    }
    try {
        $element.SetFocus()
    } catch {
        return $false
    }
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        try {
            $focused = [Windows.Automation.AutomationElement]::FocusedElement
            if ($null -ne $focused -and (Same-RuntimeId @($focused.GetRuntimeId()) @($element.GetRuntimeId()))) {
                return $true
            }
        } catch {
        }
        Start-Sleep -Milliseconds 25
    }
    return $false
}

function Test-HitElementMatchesTarget($target, [int]$screenX, [int]$screenY) {
    try {
        $point = [System.Windows.Point]::new([double]$screenX, [double]$screenY)
        $candidate = [Windows.Automation.AutomationElement]::FromPoint($point)
        $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
        for ($depth = 0; $depth -lt 16 -and $null -ne $candidate; $depth++) {
            if (Same-RuntimeId @($candidate.GetRuntimeId()) @($target.GetRuntimeId())) {
                return $true
            }
            $candidate = $walker.GetParent($candidate)
        }
    } catch {
    }
    return $false
}

function Set-ElementFocusByClickVerified($element, [int]$processId, [IntPtr]$topHwnd) {
    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
        return $false
    }
    $targetFrame = Get-ElementFrame $element $null
    if ($null -eq $targetFrame) {
        return $false
    }
    $screenX = [int][math]::Round($targetFrame.x + ($targetFrame.width / 2))
    $screenY = [int][math]::Round($targetFrame.y + ($targetFrame.height / 2))
    if (-not (Test-HitElementMatchesTarget $element $screenX $screenY)) {
        return $false
    }
    Send-ForegroundMouseClick $topHwnd $screenX $screenY "left" 1
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            $focused = [Windows.Automation.AutomationElement]::FocusedElement
            if ($null -ne $focused -and [int]$focused.Current.ProcessId -eq $processId) {
                $focusedRect = $focused.Current.BoundingRectangle
                if (-not $focusedRect.IsEmpty) {
                    $focusedCenterX = $focusedRect.X + ($focusedRect.Width / 2)
                    $focusedCenterY = $focusedRect.Y + ($focusedRect.Height / 2)
                    $insideTarget = $focusedCenterX -ge $targetFrame.x -and
                        $focusedCenterX -le ($targetFrame.x + $targetFrame.width) -and
                        $focusedCenterY -ge $targetFrame.y -and
                        $focusedCenterY -le ($targetFrame.y + $targetFrame.height)
                    if ($insideTarget) {
                        return $true
                    }
                }
                # Some accessibility providers expose only the containing window
                # after a click. Accept that degraded focus signal only because
                # UI Automation hit-testing already proved the click point belongs
                # to the requested element or one of its descendants. Exact value
                # read-back is still required before the action can succeed.
                if ($focused.Current.ControlType -eq [Windows.Automation.ControlType]::Window) {
                    return $true
                }
            }
        } catch {
        }
        Start-Sleep -Milliseconds 25
    }
    return $false
}

function Get-AllElements($root) {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add($root)
    try {
        $descendants = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $descendants.Count; $i++) {
            $items.Add($descendants.Item($i))
        }
    } catch {
    }
    return $items.ToArray()
}

function Find-Element($root, $record) {
    if ($null -eq $record) {
        return $null
    }
    foreach ($element in (Get-AllElements $root)) {
        try {
            if (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId)) {
                return $element
            }
        } catch {
        }
    }
    foreach ($element in (Get-AllElements $root)) {
        try {
            $sameAutomationId = -not [string]::IsNullOrWhiteSpace($record.automationId) -and $element.Current.AutomationId -eq $record.automationId
            $sameName = -not [string]::IsNullOrWhiteSpace($record.name) -and $element.Current.Name -eq $record.name
            $sameType = $element.Current.ControlType.ProgrammaticName -eq $record.controlType
            if (($sameAutomationId -or $sameName) -and $sameType) {
                return $element
            }
        } catch {
        }
    }
    return $null
}

function Get-CurrentPatternOrNull($element, $pattern) {
    try {
        return $element.GetCurrentPattern($pattern)
    } catch {
        return $null
    }
}

function Invoke-PreferredClick($element) {
    $invoke = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
    if ($null -ne $invoke) {
        $invoke.Invoke()
        return $true
    }
    $selection = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
    if ($null -ne $selection) {
        $selection.Select()
        return $true
    }
    $toggle = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
    if ($null -ne $toggle) {
        $toggle.Toggle()
        return $true
    }
    if (Set-ElementFocusVerified $element) {
        return $true
    }
    return $false
}

function Invoke-SecondaryAction($element, [string]$action) {
    switch ($action.ToLowerInvariant()) {
        "invoke" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Invoke(); return }
        }
        "toggle" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Toggle(); return }
        }
        "select" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Select(); return }
        }
        "expand" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Expand(); return }
        }
        "collapse" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Collapse(); return }
        }
        "scrollintoview" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.ScrollIntoView(); return }
        }
        "setfocus" {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
                throw "SetFocus is disabled by default to avoid stealing user focus; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to enable it."
            }
            if (-not (Set-ElementFocusVerified $element)) {
                throw "focus_not_acquired(element=$($operation.element.index))"
            }
            return
        }
    }
    throw "$action is not a valid secondary action for $($operation.element.index)"
}

function Invoke-Scroll($element, [string]$direction, [double]$pages) {
    $scroll = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollPattern]::Pattern)
    if ($null -eq $scroll) {
        return $false
    }
    $horizontal = [Windows.Automation.ScrollAmount]::NoAmount
    $vertical = [Windows.Automation.ScrollAmount]::NoAmount
    if ($direction -eq "up") { $vertical = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "down") { $vertical = [Windows.Automation.ScrollAmount]::LargeIncrement }
    elseif ($direction -eq "left") { $horizontal = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "right") { $horizontal = [Windows.Automation.ScrollAmount]::LargeIncrement }
    $repeat = [math]::Max(1, [int][math]::Ceiling($pages))
    for ($i = 0; $i -lt $repeat; $i++) {
        $scroll.Scroll($horizontal, $vertical)
        Start-Sleep -Milliseconds 40
    }
    return $true
}

function Find-TextEntryElement($root, [int]$processId) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $focusedValue = Get-CurrentPatternOrNull $focused ([Windows.Automation.ValuePattern]::Pattern)
            if ($null -ne $focusedValue -and -not $focusedValue.Current.IsReadOnly) {
                return $focused
            }
        }
    } catch {
    }

    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            continue
        }
        $controlType = Get-ElementControlTypeName $element
        if ($controlType -like "*Edit*" -or $controlType -like "*Document*") {
            return $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return $element
        }
    }

    return $null
}

function Get-NativeWindowHandle($element) {
    $handle = Get-ElementInt64 $element "NativeWindowHandle"
    if ($handle -le 0) {
        return [IntPtr]::Zero
    }
    return [IntPtr]$handle
}

function Test-TextWindowHandleCandidate([IntPtr]$topHwnd, $element) {
    if ($null -eq $element) {
        return $false
    }
    $handle = Get-NativeWindowHandle $element
    if ($handle -eq [IntPtr]::Zero -or $handle -eq $topHwnd) {
        return $false
    }
    $controlType = Get-ElementControlTypeName $element
    $className = Get-ElementString $element "ClassName"
    return (
        $controlType -like "*Edit*" -or
        $controlType -like "*Document*" -or
        $className -like "*Edit*" -or
        $className -like "*Rich*" -or
        $className -like "*Text*"
    )
}

function Find-TextEntryWindowHandle($root, [IntPtr]$topHwnd, $preferredElement) {
    if (Test-TextWindowHandleCandidate $topHwnd $preferredElement) {
        return Get-NativeWindowHandle $preferredElement
    }

    foreach ($element in (Get-AllElements $root)) {
        if (-not (Test-TextWindowHandleCandidate $topHwnd $element)) {
            continue
        }
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return Get-NativeWindowHandle $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        if (Test-TextWindowHandleCandidate $topHwnd $element) {
            return Get-NativeWindowHandle $element
        }
    }

    return [IntPtr]::Zero
}

function Invoke-TypeText($root, [int]$processId, [IntPtr]$topHwnd, [string]$text) {
    $element = Find-TextEntryElement $root $processId
    $targetHwnd = Find-TextEntryWindowHandle $root $topHwnd $element
    if ($targetHwnd -ne [IntPtr]::Zero -and (Send-TextToEditHandle $targetHwnd $text $element)) {
        return $true
    }

    if ($null -ne $element) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK")) {
                throw "UIA ValuePattern text fallback is disabled by default because it may bring the target app to the foreground; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 to enable it."
            }
            $current = ""
            try { $current = [string]$valuePattern.Current.Value } catch {}
            $valuePattern.SetValue($current + $text)
            return $true
        }
    }
    return $false
}

function Read-ElementTextForVerification($element) {
    if ($null -eq $element -or (Get-ElementBool $element "IsPassword")) {
        return [pscustomobject]@{ available = $false; value = "" }
    }
    $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
    if ($null -ne $valuePattern) {
        try {
            return [pscustomobject]@{ available = $true; value = [string]$valuePattern.Current.Value }
        } catch {
        }
    }
    $textPattern = Get-CurrentPatternOrNull $element ([Windows.Automation.TextPattern]::Pattern)
    if ($null -ne $textPattern) {
        try {
            return [pscustomobject]@{ available = $true; value = [string]$textPattern.DocumentRange.GetText(-1) }
        } catch {
        }
    }
    return [pscustomobject]@{ available = $false; value = "" }
}

function Set-ElementValueVerified($element, $root, [int]$processId, [IntPtr]$topHwnd, [string]$value) {
    if ($null -eq $element) {
        throw "Cannot set a value for an unknown element"
    }
    if (Get-ElementBool $element "IsPassword") {
        throw "Cannot set a value for a password element through set_value"
    }

    $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
    $setValueAttempted = $false
    if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
        try {
            $setValueAttempted = $true
            $valuePattern.SetValue($value)
            for ($attempt = 0; $attempt -lt 12; $attempt++) {
                $observed = Read-ElementTextForVerification $element
                if ($observed.available -and $observed.value -ceq $value) {
                    return "ValuePattern"
                }
                Start-Sleep -Milliseconds 25
            }
        } catch {
        }
    }

    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK")) {
        if ($setValueAttempted) {
            throw "value_not_applied(element=$($operation.element.index))"
        }
        throw "Cannot set a value for an element that is not settable"
    }
    $focusMethod = "UIAutomation"
    $focusAcquired = Set-ElementFocusVerified $element
    if (-not $focusAcquired) {
        $focusAcquired = Set-ElementFocusByClickVerified $element $processId $topHwnd
        $focusMethod = "verified-physical-click"
    }
    if (-not $focusAcquired) {
        throw "focus_not_acquired(element=$($operation.element.index))"
    }

    Send-ForegroundKey $topHwnd "ctrl+a" $processId
    Send-ForegroundText $topHwnd $processId $value
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $observed = Read-ElementTextForVerification $element
        if ($observed.available -and $observed.value -ceq $value) {
            return "SendInput:$focusMethod"
        }
        Start-Sleep -Milliseconds 25
    }
    $observed = Read-ElementTextForVerification $element
    if ($observed.available) {
        throw "value_not_applied(element=$($operation.element.index), actualLength=$($observed.value.Length), expectedLength=$($value.Length))"
    }
    throw "value_verification_unknown(element=$($operation.element.index))"
}

# Read the operation file as UTF-8 explicitly. Windows PowerShell 5.1's
# Get-Content defaults to the system ANSI code page (e.g. GBK on Chinese
# systems) for files without a BOM, which corrupts non-ASCII input such as
# Chinese text passed to set_value/type_text.
$operationJson = [System.IO.File]::ReadAllText($OperationPath, [System.Text.Encoding]::UTF8)
$operation = $operationJson | ConvertFrom-Json
$operationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$foregroundInputLock = $null

try {
    if (Test-ControlTool ([string]$operation.tool)) {
        $foregroundInputLock = Enter-ForegroundInputLock
    }
    if ($operation.tool -eq "list_apps") {
        $response = [pscustomobject]@{ ok = $true; text = (List-Apps) }
    } elseif ($operation.tool -eq "list_windows") {
        $windows = @(Get-WindowRecords ([string]$operation.app))
        $response = [pscustomobject]@{ ok = $true; text = (Format-WindowsText $windows); windows = $windows }
    } elseif ($operation.tool -eq "get_window") {
        $window = Resolve-WindowQuery ([string]$operation.app) ([string]$operation.title)
        $response = [pscustomobject]@{ ok = $true; window = $window }
    } elseif ($operation.tool -eq "launch_app") {
        $window = Launch-AppWindow ([string]$operation.app)
        $response = [pscustomobject]@{ ok = $true; window = $window }
    } elseif ($operation.tool -eq "activate_window") {
        $window = Activate-Window $operation.window
        $response = [pscustomobject]@{ ok = $true; status = "applied"; window = $window }
    } elseif ($operation.tool -eq "get_window_state") {
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot "" (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) $operation.window) }
    } elseif ($operation.tool -eq "get_app_state") {
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth)) }
    } elseif ($operation.tool -eq "coordinate_self_test") {
        $response = [pscustomobject]@{ ok = $true; text = ((Test-CoordinateMappingContract) | ConvertTo-Json -Compress -Depth 6) }
    } else {
        $context = Resolve-ActionContext $operation
        $process = $context.process
        $hwnd = $context.hwnd
        $window = $context.window
        $root = $context.root
        $requestedWindowBounds = Get-OperationPropertyValue $operation "windowBounds"
        $windowBounds = if ($null -ne $requestedWindowBounds) { $requestedWindowBounds } else { $context.windowBounds }
        $requestedCapture = Get-OperationPropertyValue $operation "capture"
        $element = $context.element
        $isWindowScoped = $null -ne (Get-OperationPropertyValue $operation "window")

        if ($isWindowScoped -and $null -ne $requestedWindowBounds) {
            Assert-WindowBoundsMatch $requestedWindowBounds $context.windowBounds
        }

        switch ($operation.tool) {
            "click" {
                $clickMethod = [string]$operation.click_method
                if ([string]::IsNullOrWhiteSpace($clickMethod)) { $clickMethod = "auto" }

                if ($clickMethod -eq "accessibility") {
                    if ($null -eq $element) { throw "click_method 'accessibility' requires element_index" }
                    if ($operation.mouse_button -eq "right" -or $operation.mouse_button -eq "middle") {
                        throw "click_method 'accessibility' does not support mouse_button '$($operation.mouse_button)'"
                    }
                    if (-not (Invoke-PreferredClick $element)) {
                        throw "click_method 'accessibility' could not click the requested element"
                    }
                } elseif ($clickMethod -eq "app_post") {
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = Convert-ScreenshotPoint ([double]$operation.x) ([double]$operation.y) $windowBounds $requestedCapture "click"
                    }
                    if ($isWindowScoped) {
                        Send-ForegroundMouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                    } else {
                        Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                    }
                } elseif ($clickMethod -eq "global") {
                    throw "click_method 'global' is not supported on Windows"
                } elseif ($clickMethod -eq "sky_click") {
                    throw "click_method 'sky_click' is not supported on Windows"
                } elseif ($clickMethod -eq "auto") {
                    $handled = $false
                    if ($null -ne $element -and $operation.mouse_button -ne "right" -and $operation.mouse_button -ne "middle") {
                        $handled = Invoke-PreferredClick $element
                    }
                    if (-not $handled) {
                        if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                            $point = Get-ScreenPoint $operation.element.frame $windowBounds
                        } else {
                            $point = Convert-ScreenshotPoint ([double]$operation.x) ([double]$operation.y) $windowBounds $requestedCapture "click"
                        }
                        if ($isWindowScoped) {
                            Send-ForegroundMouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                        } else {
                            Send-MouseClick $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                        }
                    }
                } else {
                    throw "Invalid click_method '$clickMethod'"
                }
            }
            "perform_secondary_action" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                Invoke-SecondaryAction $element $operation.action
            }
            "scroll" {
                $handled = $false
                if ($null -ne $element) {
                    $handled = Invoke-Scroll $element $operation.direction ([double]$operation.pages)
                }
                if (-not $handled) {
                    $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    if ($isWindowScoped) {
                        Send-ForegroundScroll $hwnd $point.x $point.y $operation.direction ([double]$operation.pages)
                    } else {
                        Send-Scroll $hwnd $point.x $point.y $operation.direction ([double]$operation.pages)
                    }
                }
            }
            "drag" {
                $from = Convert-ScreenshotPoint ([double]$operation.from_x) ([double]$operation.from_y) $windowBounds $requestedCapture "drag.from"
                $to = Convert-ScreenshotPoint ([double]$operation.to_x) ([double]$operation.to_y) $windowBounds $requestedCapture "drag.to"
                if ($isWindowScoped) {
                    Send-ForegroundDrag $hwnd $from.x $from.y $to.x $to.y
                } else {
                    Send-Drag $hwnd $from.x $from.y $to.x $to.y
                }
            }
            "type_text" {
                if ($isWindowScoped) {
                    Send-ForegroundText $hwnd $process.Id $operation.text
                } elseif (-not (Invoke-TypeText $root $process.Id $hwnd $operation.text)) {
                    Send-Text $hwnd $operation.text
                }
            }
            "press_key" {
                if ($isWindowScoped) {
                    Send-ForegroundKey $hwnd $operation.key
                } else {
                    Send-Key $hwnd $operation.key
                }
            }
            "set_value" {
                if ($null -eq $element) { throw "unknown element_index '$($operation.element.index)'" }
                [void](Set-ElementValueVerified $element $root $process.Id $hwnd ([string]$operation.value))
            }
            default {
                throw "unsupportedTool(`"$($operation.tool)`")"
            }
        }

        Start-Sleep -Milliseconds 120
        $snapshot = if ([OCUWin32]::IsWindow($hwnd)) {
            try {
                Build-Snapshot "" (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) $window
            } catch {
                if (($_.Exception.Message -like "stale_window*" -or $_.Exception.Message -like "window_not_found*") -and -not [OCUWin32]::IsWindow($hwnd)) {
                    New-ClosedWindowSnapshot $process $window
                } else {
                    throw
                }
            }
        } else {
            New-ClosedWindowSnapshot $process $window
        }
        $postcondition = Test-ExpectedPostcondition (Get-OperationPropertyValue $operation "expected_postcondition") $operation $snapshot $hwnd
        $status = if ($null -ne $postcondition -and -not $postcondition.satisfied) {
            "unknown"
        } else {
            if ($snapshot.windowClosed -and $null -eq $postcondition) { "unknown" } else { "applied" }
        }
        if ($null -ne $postcondition) {
            $snapshot | Add-Member -NotePropertyName postcondition -NotePropertyValue $postcondition -Force
        }
        $snapshot | Add-Member -NotePropertyName actionStatus -NotePropertyValue $status -Force
        $response = [pscustomobject]@{ ok = $true; status = $status; snapshot = $snapshot }
    }
} catch {
    $message = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) {
        $message = "$message at $($_.ScriptStackTrace)"
    }
    $status = ""
    if (Test-MutatingTool ([string]$operation.tool)) {
        $status = Resolve-ActionFailureStatus $message
    }
    $response = [pscustomobject]@{ ok = $false; error = $message; status = $status }
} finally {
    Exit-ForegroundInputLock $foregroundInputLock
    $operationStopwatch.Stop()
}

if ($null -ne $response.snapshot -and (Test-MutatingTool ([string]$operation.tool))) {
    $response.snapshot | Add-Member -NotePropertyName actionId -NotePropertyValue ([string](Get-OperationPropertyValue $operation "action_id")) -Force
    $response.snapshot | Add-Member -NotePropertyName actionDurationMs -NotePropertyValue ([long]$operationStopwatch.ElapsedMilliseconds) -Force
}

$response | ConvertTo-Json -Depth 50 -Compress
