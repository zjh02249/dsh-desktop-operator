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

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

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

    public static void ClickAt(int x, int y, uint downFlag, uint upFlag, int count) {
        if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed");
        int repeat = Math.Max(1, count);
        for (int i = 0; i < repeat; i++) {
            SendInputChecked(new[] { MouseInput(downFlag, 0), MouseInput(upFlag, 0) });
            Thread.Sleep(50);
        }
    }

    public static void DragTo(int fromX, int fromY, int toX, int toY) {
        if (!SetCursorPos(fromX, fromY)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed");
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
        if (!SetCursorPos(x, y)) throw new Win32Exception(Marshal.GetLastWin32Error(), "SetCursorPos failed");
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
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        Add-Type -TypeDefinition $win32Source -ErrorAction Stop
        $addTypeFailure = $null
        break
    } catch {
        $addTypeFailure = $_
        if ($attempt -lt 3 -and $_.FullyQualifiedErrorId -like "SOURCE_CODE_ERROR*") {
            Start-Sleep -Milliseconds (100 * $attempt)
            continue
        }
        break
    }
}
if ($null -ne $addTypeFailure) {
    throw $addTypeFailure
}

$GW_OWNER = 4
$SW_RESTORE = 9

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

function Assert-ForegroundWindow([IntPtr]$hwnd) {
    $foreground = [OCUWin32]::GetForegroundWindow()
    if ($foreground -ne $hwnd) {
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
    Assert-ForegroundWindow $hwnd
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

function Send-ForegroundKey([IntPtr]$hwnd, [string]$key) {
    Assert-ForegroundWindow $hwnd
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

function Capture-WindowPngBase64($bounds) {
    if ($null -eq $bounds -or $bounds.width -le 0 -or $bounds.height -le 0) {
        return $null
    }
    try {
        $bitmap = New-Object System.Drawing.Bitmap ([int][math]::Round($bounds.width)), ([int][math]::Round($bounds.height))
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen([int][math]::Round($bounds.x), [int][math]::Round($bounds.y), 0, 0, $bitmap.Size)
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        $bytes = $stream.ToArray()
        $stream.Dispose()
        return [Convert]::ToBase64String($bytes)
    } catch {
        return $null
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
    $snapshotID = ("{0}:{1}" -f $window.generation, [DateTime]::UtcNow.Ticks)
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
        }
        window = $window
        observationId = $snapshotID
        screenshotId = $snapshotID
        windowTitle = Limit-Text $window.title $TextLimit
        windowBounds = $bounds
        screenshotPngBase64 = Capture-WindowPngBase64 $bounds
        treeLines = @($rendered.lines)
        focusedSummary = Get-FocusedSummary $process.Id $TextLimit
        selectedText = Get-SelectedText $process.Id $TextLimit
        elements = @($rendered.records)
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

function Resolve-ActionFailureStatus([string]$message) {
    if (
        $message -like "stale_window*" -or
        $message -like "invalid_window_ref*" -or
        $message -like "foreground_not_acquired*" -or
        $message -like "focused_element_not_in_target*" -or
        $message -like "focused_element_unknown*" -or
        $message -like "occluded_by_non_target*" -or
        $message -like "unknown element_index*" -or
        $message -like "Missing required argument:*" -or
        $message -like "Cannot set a value*" -or
        $message -like "click_method *" -or
        $message -like "Unsupported key:*"
    ) {
        return "rejected"
    }
    return "unknown"
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
    if ($null -eq $left -or $null -eq $right -or $left.Count -ne $right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $left.Count; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) {
            return $false
        }
    }
    return $true
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
    if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS") {
        try {
            if ($element.Current.IsKeyboardFocusable) {
                $element.SetFocus()
                return $true
            }
        } catch {
        }
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
            $element.SetFocus()
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

# Read the operation file as UTF-8 explicitly. Windows PowerShell 5.1's
# Get-Content defaults to the system ANSI code page (e.g. GBK on Chinese
# systems) for files without a BOM, which corrupts non-ASCII input such as
# Chinese text passed to set_value/type_text.
$operationJson = [System.IO.File]::ReadAllText($OperationPath, [System.Text.Encoding]::UTF8)
$operation = $operationJson | ConvertFrom-Json

try {
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
    } else {
        $context = Resolve-ActionContext $operation
        $process = $context.process
        $hwnd = $context.hwnd
        $window = $context.window
        $root = $context.root
        $requestedWindowBounds = Get-OperationPropertyValue $operation "windowBounds"
        $windowBounds = if ($null -ne $requestedWindowBounds) { $requestedWindowBounds } else { $context.windowBounds }
        $element = $context.element
        $isWindowScoped = $null -ne (Get-OperationPropertyValue $operation "window")

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
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
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
                            $point = [pscustomobject]@{
                                x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                                y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                            }
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
                $fromX = [int][math]::Round($windowBounds.x + [double]$operation.from_x)
                $fromY = [int][math]::Round($windowBounds.y + [double]$operation.from_y)
                $toX = [int][math]::Round($windowBounds.x + [double]$operation.to_x)
                $toY = [int][math]::Round($windowBounds.y + [double]$operation.to_y)
                if ($isWindowScoped) {
                    Send-ForegroundDrag $hwnd $fromX $fromY $toX $toY
                } else {
                    Send-Drag $hwnd $fromX $fromY $toX $toY
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
                $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
                if ($null -eq $valuePattern) {
                    throw "Cannot set a value for an element that is not settable"
                }
                $valuePattern.SetValue($operation.value)
            }
            default {
                throw "unsupportedTool(`"$($operation.tool)`")"
            }
        }

        Start-Sleep -Milliseconds 120
        $snapshot = Build-Snapshot "" (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) $window
        $snapshot | Add-Member -NotePropertyName actionStatus -NotePropertyValue "applied" -Force
        $response = [pscustomobject]@{ ok = $true; status = "applied"; snapshot = $snapshot }
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
}

$response | ConvertTo-Json -Depth 50 -Compress
