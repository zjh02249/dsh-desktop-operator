param(
    [Parameter(Mandatory = $true)]
    [string]$StateDirectory,

    [Parameter(Mandatory = $true)]
    [int]$OwnerProcessId
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$nativeSource = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class DeepSeekIndicatorNative {
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_NOACTIVATE = 0x08000000;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint flags
    );

    public static void EnableDpiAwareness() {
        try {
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return;
        } catch (EntryPointNotFoundException) {
        }
        SetProcessDPIAware();
    }
}

public sealed class DeepSeekControlIndicatorForm : Form {
    private const int WM_NCHITTEST = 0x0084;
    private static readonly IntPtr HTTRANSPARENT = new IntPtr(-1);

    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams {
        get {
            CreateParams parameters = base.CreateParams;
            parameters.ExStyle |= DeepSeekIndicatorNative.WS_EX_TRANSPARENT;
            parameters.ExStyle |= DeepSeekIndicatorNative.WS_EX_TOOLWINDOW;
            parameters.ExStyle |= DeepSeekIndicatorNative.WS_EX_NOACTIVATE;
            return parameters;
        }
    }

    protected override void WndProc(ref Message message) {
        if (message.Msg == WM_NCHITTEST) {
            message.Result = HTTRANSPARENT;
            return;
        }
        base.WndProc(ref message);
    }
}
"@

Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies @(
    "System.Drawing",
    "System.Windows.Forms"
)

[DeepSeekIndicatorNative]::EnableDpiAwareness()

[System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
$statePath = Join-Path $StateDirectory "control-state.json"
$readyPath = Join-Path $StateDirectory "control-ready.json"
$mutexHasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $mutexBytes = [System.Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($StateDirectory).ToLowerInvariant())
    $mutexKey = (($mutexHasher.ComputeHash($mutexBytes) | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
} finally {
    $mutexHasher.Dispose()
}
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, "Local\DeepSeekHarnessComputerUseIndicator-$mutexKey", [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$virtualScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
$primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$script:currentAction = ""
$script:isActive = $false
$script:hasPainted = $false
$script:nextOwnerCheckUtc = [DateTime]::MinValue

function Write-ReadyState {
    $ready = [ordered]@{
        pid = $PID
        heartbeatUtc = [DateTime]::UtcNow.ToString("o")
        visible = $script:isActive -and $script:hasPainted
    } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($readyPath, $ready, $utf8NoBom)
}

function Get-ActionLabel([string]$Action) {
    switch ($Action) {
        "activate_window" { return "切换窗口" }
        "launch_app" { return "启动应用" }
        "click" { return "移动并单击鼠标" }
        "drag" { return "拖动鼠标" }
        "scroll" { return "滚动页面" }
        "type_text" { return "输入文字" }
        "press_key" { return "按下按键" }
        "set_value" { return "填写控件" }
        "perform_secondary_action" { return "操作控件" }
        default { return "操作桌面" }
    }
}

$form = [DeepSeekControlIndicatorForm]::new()
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.BackColor = [System.Drawing.Color]::Magenta
$form.TransparencyKey = [System.Drawing.Color]::Magenta
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds = $virtualScreen
$form.TopMost = $true

$form.add_Shown({
    [void][DeepSeekIndicatorNative]::SetWindowPos(
        $form.Handle,
        [DeepSeekIndicatorNative]::HWND_TOPMOST,
        0,
        0,
        0,
        0,
        [DeepSeekIndicatorNative]::SWP_NOMOVE -bor
            [DeepSeekIndicatorNative]::SWP_NOSIZE -bor
            [DeepSeekIndicatorNative]::SWP_NOACTIVATE
    )
    Write-ReadyState
})

$form.add_Paint({
    param($sender, $eventArgs)

    if (-not $script:isActive) { return }

    $graphics = $eventArgs.Graphics
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $scale = [math]::Max(1.0, $graphics.DpiX / 96.0)

    $point = [DeepSeekIndicatorNative+POINT]::new()
    if ([DeepSeekIndicatorNative]::GetCursorPos([ref]$point)) {
        $cursorX = $point.X - $virtualScreen.X
        $cursorY = $point.Y - $virtualScreen.Y
        $haloRadius = [int][math]::Round(24 * $scale)
        $ringRadius = [int][math]::Round(20 * $scale)
        $centerRadius = [int][math]::Round(4 * $scale)
        $haloBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(72, 255, 112, 56))
        $ringPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(245, 255, 112, 56), [single](4 * $scale))
        $centerBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(245, 255, 112, 56))
        try {
            $graphics.FillEllipse($haloBrush, $cursorX - $haloRadius, $cursorY - $haloRadius, $haloRadius * 2, $haloRadius * 2)
            $graphics.DrawEllipse($ringPen, $cursorX - $ringRadius, $cursorY - $ringRadius, $ringRadius * 2, $ringRadius * 2)
            $graphics.FillEllipse($centerBrush, $cursorX - $centerRadius, $cursorY - $centerRadius, $centerRadius * 2, $centerRadius * 2)
        } finally {
            $haloBrush.Dispose()
            $ringPen.Dispose()
            $centerBrush.Dispose()
        }
    }

    $badgeWidth = [int][math]::Round(520 * $scale)
    $badgeHeight = [int][math]::Round(48 * $scale)
    $badgeX = ($primaryScreen.X - $virtualScreen.X) + [int](($primaryScreen.Width - $badgeWidth) / 2)
    $badgeY = ($primaryScreen.Y - $virtualScreen.Y) + [int][math]::Round(18 * $scale)
    $badgeBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(235, 28, 31, 38))
    $accentBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 112, 56))
    $textBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $font = [System.Drawing.Font]::new("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
    $textFormat = [System.Drawing.StringFormat]::new()
    $textFormat.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
    $textFormat.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
    try {
        $graphics.FillRectangle($badgeBrush, $badgeX, $badgeY, $badgeWidth, $badgeHeight)
        $accentOffset = [int][math]::Round(16 * $scale)
        $accentSize = [int][math]::Round(16 * $scale)
        $graphics.FillEllipse($accentBrush, $badgeX + $accentOffset, $badgeY + $accentOffset, $accentSize, $accentSize)
        $label = "DeepSeek 正在控制电脑 · $(Get-ActionLabel $script:currentAction)"
        $textX = $badgeX + [int][math]::Round(44 * $scale)
        $textY = $badgeY + [int][math]::Round(10 * $scale)
        $textWidth = $badgeWidth - [int][math]::Round(56 * $scale)
        $textHeight = $badgeHeight - [int][math]::Round(12 * $scale)
        $textBounds = [System.Drawing.RectangleF]::new($textX, $textY, $textWidth, $textHeight)
        $graphics.DrawString($label, $font, $textBrush, $textBounds, $textFormat)
    } finally {
        $badgeBrush.Dispose()
        $accentBrush.Dispose()
        $textBrush.Dispose()
        $font.Dispose()
        $textFormat.Dispose()
    }
    $script:hasPainted = $true
    Write-ReadyState
})

$timer = [System.Windows.Forms.Timer]::new()
$context = [System.Windows.Forms.ApplicationContext]::new()
$timer.Interval = 50
$timer.add_Tick({
    try {
        if ([DateTime]::UtcNow -ge $script:nextOwnerCheckUtc) {
            $script:nextOwnerCheckUtc = [DateTime]::UtcNow.AddSeconds(1)
            try {
                $ownerProcess = [System.Diagnostics.Process]::GetProcessById($OwnerProcessId)
                $ownerProcess.Dispose()
            } catch {
                $form.Close()
                $context.ExitThread()
                return
            }
        }
        if (-not [System.IO.File]::Exists($statePath)) {
            $form.Close()
            $context.ExitThread()
            return
        }
        $state = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $updated = [DateTime]::Parse(
            [string]$state.updatedAtUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        $ageSeconds = ([DateTime]::UtcNow - $updated.ToUniversalTime()).TotalSeconds
        if (-not [bool]$state.active) {
            $script:isActive = $false
            $script:hasPainted = $false
            if ($form.Visible) { $form.Hide() }
            Write-ReadyState
            if ($ageSeconds -gt 600) {
                $form.Close()
                $context.ExitThread()
            }
            return
        }
        if ($ageSeconds -gt 120) {
            $form.Close()
            $context.ExitThread()
            return
        }
        $script:currentAction = [string]$state.action
        if (-not $script:isActive) { $script:hasPainted = $false }
        $script:isActive = $true
        if (-not $form.Visible) { $form.Show() }
        [void][DeepSeekIndicatorNative]::SetWindowPos(
            $form.Handle,
            [DeepSeekIndicatorNative]::HWND_TOPMOST,
            0,
            0,
            0,
            0,
            [DeepSeekIndicatorNative]::SWP_NOMOVE -bor
                [DeepSeekIndicatorNative]::SWP_NOSIZE -bor
                [DeepSeekIndicatorNative]::SWP_NOACTIVATE
        )
        Write-ReadyState
        $form.Invalidate()
    } catch {
        # A writer may be replacing the tiny JSON file. Keep the last good state
        # and retry on the next 50 ms tick rather than flashing the overlay.
    }
})

try {
    Write-ReadyState
    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
} finally {
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
    $context.Dispose()
    try {
        if ([System.IO.File]::Exists($readyPath)) {
            $ready = [System.IO.File]::ReadAllText($readyPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ([int]$ready.pid -eq $PID) {
                [System.IO.File]::Delete($readyPath)
            }
        }
    } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
