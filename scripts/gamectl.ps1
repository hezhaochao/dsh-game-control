# dsh-game-control — PowerShell SendInput 后端
#
# 由 mcp/server.mjs 以子进程调用：
#   powershell -NoProfile -ExecutionPolicy Bypass -File gamectl.ps1 -Action <名> -Json <payload>
# 标准输出必须是单个 JSON 对象（{ ok: true, ... } / { ok: false, error }）。
#
# 关键点：键盘走 SendInput 的 SCAN CODE 模式（KEYEVENTF_SCANCODE，wVk=0）——
# 游戏读的是扫描码而不是虚拟键，普通 SendMessage/SendKeys 在多数游戏里无效。
# 鼠标支持绝对移动与相对移动（相对移动用于镜头/视角控制）。
# 进程启动时声明 DPI Aware，保证所有坐标都是物理像素。
# 结构体交互全部封装在 C# 侧（返回托管数组），绕开 PS 5.1 的 out 结构体封送坑。
# 注意：本文件必须保存为 UTF-8 with BOM，否则 PowerShell 5.1 会按 ANSI 误读中文。
param(
  [Parameter(Mandatory = $true)][string]$Action,
  [string]$Json = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace GameCtlNative {
  [StructLayout(LayoutKind.Sequential)]
  public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags;
    public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags;
    public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct INPUT {
    public uint type; public INPUTUNION U;
  }
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  public static class Native {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;
    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint KEYEVENTF_SCANCODE = 0x0008;
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    public const uint MOUSEEVENTF_WHEEL = 0x0800;
    public const uint MOUSEEVENTF_HWHEEL = 0x1000;
    public const uint MOUSEEVENTF_ABSOLUTE = 0x8000;

    // PS/2 Set 1 make codes。导航键、win 键带 0xE0 前缀，需要 EXTENDED 标记。
    // 数组第二位：1 = extended。
    private static readonly Dictionary<string, ushort[]> ScanMap = new Dictionary<string, ushort[]>(StringComparer.OrdinalIgnoreCase) {
      {"escape", new ushort[]{0x01,0}}, {"esc", new ushort[]{0x01,0}},
      {"1", new ushort[]{0x02,0}}, {"2", new ushort[]{0x03,0}}, {"3", new ushort[]{0x04,0}},
      {"4", new ushort[]{0x05,0}}, {"5", new ushort[]{0x06,0}}, {"6", new ushort[]{0x07,0}},
      {"7", new ushort[]{0x08,0}}, {"8", new ushort[]{0x09,0}}, {"9", new ushort[]{0x0A,0}},
      {"0", new ushort[]{0x0B,0}},
      {"minus", new ushort[]{0x0C,0}}, {"equal", new ushort[]{0x0D,0}}, {"backspace", new ushort[]{0x0E,0}},
      {"tab", new ushort[]{0x0F,0}},
      {"q", new ushort[]{0x10,0}}, {"w", new ushort[]{0x11,0}}, {"e", new ushort[]{0x12,0}},
      {"r", new ushort[]{0x13,0}}, {"t", new ushort[]{0x14,0}}, {"y", new ushort[]{0x15,0}},
      {"u", new ushort[]{0x16,0}}, {"i", new ushort[]{0x17,0}}, {"o", new ushort[]{0x18,0}},
      {"p", new ushort[]{0x19,0}},
      {"bracket_left", new ushort[]{0x1A,0}}, {"bracket_right", new ushort[]{0x1B,0}},
      {"enter", new ushort[]{0x1C,0}}, {"return", new ushort[]{0x1C,0}},
      {"ctrl", new ushort[]{0x1D,0}}, {"control", new ushort[]{0x1D,0}},
      {"a", new ushort[]{0x1E,0}}, {"s", new ushort[]{0x1F,0}}, {"d", new ushort[]{0x20,0}},
      {"f", new ushort[]{0x21,0}}, {"g", new ushort[]{0x22,0}}, {"h", new ushort[]{0x23,0}},
      {"j", new ushort[]{0x24,0}}, {"k", new ushort[]{0x25,0}}, {"l", new ushort[]{0x26,0}},
      {"semicolon", new ushort[]{0x27,0}}, {"quote", new ushort[]{0x28,0}},
      {"grave", new ushort[]{0x29,0}}, {"shift", new ushort[]{0x2A,0}},
      {"backslash", new ushort[]{0x2B,0}},
      {"z", new ushort[]{0x2C,0}}, {"x", new ushort[]{0x2D,0}}, {"c", new ushort[]{0x2E,0}},
      {"v", new ushort[]{0x2F,0}}, {"b", new ushort[]{0x30,0}}, {"n", new ushort[]{0x31,0}},
      {"m", new ushort[]{0x32,0}},
      {"comma", new ushort[]{0x33,0}}, {"period", new ushort[]{0x34,0}}, {"slash", new ushort[]{0x35,0}},
      {"alt", new ushort[]{0x38,0}}, {"space", new ushort[]{0x39,0}},
      {"capslock", new ushort[]{0x3A,0}},
      {"f1", new ushort[]{0x3B,0}}, {"f2", new ushort[]{0x3C,0}}, {"f3", new ushort[]{0x3D,0}},
      {"f4", new ushort[]{0x3E,0}}, {"f5", new ushort[]{0x3F,0}}, {"f6", new ushort[]{0x40,0}},
      {"f7", new ushort[]{0x41,0}}, {"f8", new ushort[]{0x42,0}}, {"f9", new ushort[]{0x43,0}},
      {"f10", new ushort[]{0x44,0}},
      {"numlock", new ushort[]{0x45,0}}, {"scrolllock", new ushort[]{0x46,0}},
      {"numpad7", new ushort[]{0x47,0}}, {"numpad8", new ushort[]{0x48,0}}, {"numpad9", new ushort[]{0x49,0}},
      {"numpad_minus", new ushort[]{0x4A,0}},
      {"numpad4", new ushort[]{0x4B,0}}, {"numpad5", new ushort[]{0x4C,0}}, {"numpad6", new ushort[]{0x4D,0}},
      {"numpad_plus", new ushort[]{0x4E,0}},
      {"numpad1", new ushort[]{0x4F,0}}, {"numpad2", new ushort[]{0x50,0}}, {"numpad3", new ushort[]{0x51,0}},
      {"numpad0", new ushort[]{0x52,0}}, {"numpad_period", new ushort[]{0x53,0}},
      {"f11", new ushort[]{0x57,0}}, {"f12", new ushort[]{0x58,0}},
      {"win", new ushort[]{0x5B,1}},
      {"up", new ushort[]{0x48,1}}, {"down", new ushort[]{0x50,1}},
      {"left", new ushort[]{0x4B,1}}, {"right", new ushort[]{0x4D,1}},
      {"home", new ushort[]{0x47,1}}, {"end", new ushort[]{0x4F,1}},
      {"pgup", new ushort[]{0x49,1}}, {"pgdn", new ushort[]{0x51,1}},
      {"insert", new ushort[]{0x52,1}}, {"delete", new ushort[]{0x53,1}}
    };

    public static bool TryScan(string name, out ushort scan, out bool extended) {
      scan = 0; extended = false;
      ushort[] v;
      if (!ScanMap.TryGetValue(name ?? "", out v)) return false;
      scan = v[0]; extended = v[1] != 0;
      return true;
    }

    public static void KeyScan(ushort scan, bool up, bool extended) {
      INPUT[] inputs = new INPUT[1];
      inputs[0].type = INPUT_KEYBOARD;
      inputs[0].U.ki = new KEYBDINPUT {
        wVk = 0, wScan = scan,
        dwFlags = KEYEVENTF_SCANCODE | (up ? KEYEVENTF_KEYUP : 0) | (extended ? KEYEVENTF_EXTENDEDKEY : 0),
        time = 0, dwExtraInfo = IntPtr.Zero
      };
      if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1)
        throw new InvalidOperationException("SendInput did not accept the keyboard event");
    }

    public static void Mouse(uint flags, int dx, int dy, int mouseData) {
      INPUT[] inputs = new INPUT[1];
      inputs[0].type = INPUT_MOUSE;
      inputs[0].U.mi = new MOUSEINPUT {
        dx = dx, dy = dy, mouseData = unchecked((uint)mouseData),
        dwFlags = flags, time = 0, dwExtraInfo = IntPtr.Zero
      };
      if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1)
        throw new InvalidOperationException("SendInput did not accept the mouse event");
    }

    // 以下包装把 out 结构体留在 C# 侧，PowerShell 只接触数组/标量。

    public static int[] CursorPos() {
      POINT p;
      if (!GetCursorPos(out p)) throw new InvalidOperationException("GetCursorPos failed");
      return new int[] { p.X, p.Y };
    }

    public static int[] MoveCursor(int x, int y) {
      if (!SetCursorPos(x, y)) throw new InvalidOperationException("SetCursorPos failed");
      return CursorPos();
    }

    public static int[] MoveCursorRelative(int dx, int dy) {
      Mouse(MOUSEEVENTF_MOVE, dx, dy, 0);
      return CursorPos();
    }

    public static int ScreenWidth() { return GetSystemMetrics(0); }
    public static int ScreenHeight() { return GetSystemMetrics(1); }

    public static List<object[]> VisibleWindows() {
      List<object[]> list = new List<object[]>();
      EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
        if (IsWindowVisible(hWnd)) {
          System.Text.StringBuilder sb = new System.Text.StringBuilder(512);
          GetWindowText(hWnd, sb, 512);
          string title = sb.ToString();
          if (title.Length > 0) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            RECT r;
            GetWindowRect(hWnd, out r);
            list.Add(new object[] { hWnd.ToInt64(), (long)pid, title,
              (long)r.Left, (long)r.Top, (long)(r.Right - r.Left), (long)(r.Bottom - r.Top) });
          }
        }
        return true;
      }, IntPtr.Zero);
      return list;
    }

    public static long[] WindowRect(IntPtr hWnd) {
      RECT r;
      if (!GetWindowRect(hWnd, out r)) throw new InvalidOperationException("GetWindowRect failed");
      return new long[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
    }

    public static bool ForceForeground(IntPtr hWnd) {
      if (IsIconic(hWnd)) ShowWindow(hWnd, 9); // SW_RESTORE
      IntPtr fore = GetForegroundWindow();
      uint foreThread = 0;
      if (fore != IntPtr.Zero) GetWindowThreadProcessId(fore, out foreThread);
      uint thisThread = GetCurrentThreadId();
      bool attached = false;
      if (foreThread != 0 && foreThread != thisThread)
        attached = AttachThreadInput(thisThread, foreThread, true);
      try { SetForegroundWindow(hWnd); }
      finally { if (attached) AttachThreadInput(thisThread, foreThread, false); }
      return GetForegroundWindow() == hWnd;
    }
  }
}
'@

[void][GameCtlNative.Native]::SetProcessDPIAware()

function Out-Json($object) {
  $json = $object | ConvertTo-Json -Compress -Depth 5
  # 非 ASCII 一律转成 \uXXXX：后端 stdout 永远是纯 ASCII，
  # 不论父子进程控制台编码如何（GBK/UTF-8）都能被安全解析。
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    if ([int]$ch -gt 127) {
      [void]$sb.Append(('\u' + ([int]$ch).ToString('x4')))
    } else {
      [void]$sb.Append($ch)
    }
  }
  Write-Output $sb.ToString()
}

function Fail($message) {
  Out-Json @{ ok = $false; error = [string]$message }
  exit 0
}

try {
  # 优先用环境变量拿 payload：JSON 走 -File 命令行参数会被 PS 5.1 的
  # 原生参数传递规则吃掉引号（已在真机踩坑验证），env 传输则完全无损。
  $jsonText = $env:GAMECTL_JSON
  if (-not $jsonText) { $jsonText = $Json }
  $payload = $jsonText | ConvertFrom-Json
} catch {
  Fail "payload JSON 解析失败: $($_.Exception.Message)"
}

function Get-Int($value, $fallback) {
  if ($null -eq $value) { return $fallback }
  $n = 0
  if ([int]::TryParse([string]$value, [ref]$n)) { return $n }
  return $fallback
}

function Send-Key([string]$name, [string]$mode, [int]$durationMs) {
  $scan = [uint16]0
  $ext = $false
  if (-not [GameCtlNative.Native]::TryScan($name, [ref]$scan, [ref]$ext)) {
    throw "未知按键名: '$name'（支持 a-z、0-9、f1-f12、方向键、space/enter/esc/tab/shift/ctrl/alt 等）"
  }
  if ($mode -eq 'down') {
    [GameCtlNative.Native]::KeyScan($scan, $false, $ext)
    return @{ key = $name.ToLower(); scan = $scan; mode = 'down' }
  }
  if ($mode -eq 'up') {
    [GameCtlNative.Native]::KeyScan($scan, $true, $ext)
    return @{ key = $name.ToLower(); scan = $scan; mode = 'up' }
  }
  [GameCtlNative.Native]::KeyScan($scan, $false, $ext)
  if ($durationMs -gt 0) { Start-Sleep -Milliseconds $durationMs }
  [GameCtlNative.Native]::KeyScan($scan, $true, $ext)
  return @{ key = $name.ToLower(); scan = $scan; mode = 'tap'; ms = $durationMs }
}

$BUTTON_FLAGS = @{
  left   = @{ down = [GameCtlNative.Native]::MOUSEEVENTF_LEFTDOWN; up = [GameCtlNative.Native]::MOUSEEVENTF_LEFTUP }
  right  = @{ down = [GameCtlNative.Native]::MOUSEEVENTF_RIGHTDOWN; up = [GameCtlNative.Native]::MOUSEEVENTF_RIGHTUP }
  middle = @{ down = [GameCtlNative.Native]::MOUSEEVENTF_MIDDLEDOWN; up = [GameCtlNative.Native]::MOUSEEVENTF_MIDDLEUP }
}

function Invoke-Click([string]$button, [object]$isDouble, [int]$holdMs) {
  if (-not $BUTTON_FLAGS.ContainsKey($button)) { throw "未知鼠标键: '$button'" }
  $flags = $BUTTON_FLAGS[$button]
  [GameCtlNative.Native]::Mouse($flags.down, 0, 0, 0)
  if ($holdMs -gt 0) { Start-Sleep -Milliseconds $holdMs }
  [GameCtlNative.Native]::Mouse($flags.up, 0, 0, 0)
  if ($isDouble) {
    Start-Sleep -Milliseconds 60
    [GameCtlNative.Native]::Mouse($flags.down, 0, 0, 0)
    Start-Sleep -Milliseconds 30
    [GameCtlNative.Native]::Mouse($flags.up, 0, 0, 0)
  }
}

function Invoke-Wheel([int]$delta, [object]$horizontal) {
  $flags = [GameCtlNative.Native]::MOUSEEVENTF_WHEEL
  if ($horizontal) { $flags = [GameCtlNative.Native]::MOUSEEVENTF_HWHEEL }
  [GameCtlNative.Native]::Mouse($flags, 0, 0, $delta)
}

switch ($Action) {

  'pos' {
    $pos = [GameCtlNative.Native]::CursorPos()
    Out-Json @{ ok = $true; x = $pos[0]; y = $pos[1]
      screen_w = [GameCtlNative.Native]::ScreenWidth()
      screen_h = [GameCtlNative.Native]::ScreenHeight() }
  }

  'screenshot' {
    Add-Type -AssemblyName System.Drawing | Out-Null
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $x = $bounds.X; $y = $bounds.Y; $w = $bounds.Width; $h = $bounds.Height
    if ($payload.region) {
      $r = @($payload.region)
      if ($r.Count -ge 4) {
        $x = Get-Int $r[0] $x; $y = Get-Int $r[1] $y
        $w = Get-Int $r[2] $w; $h = Get-Int $r[3] $h
      }
    }
    if ($w -le 0 -or $h -le 0) { Fail "无效的截图区域: ${w}x${h}" }
    $outPath = [string]$payload.out
    if (-not $outPath) {
      $outPath = Join-Path ([System.IO.Path]::GetTempPath()) ("gamectl-" + [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff') + ".png")
    }
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    try {
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      try { $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h))) }
      finally { $g.Dispose() }
      $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bmp.Dispose() }
    $info = Get-Item -LiteralPath $outPath
    Out-Json @{ ok = $true; path = $info.FullName; width = $w; height = $h; bytes = $info.Length }
  }

  'key' {
    $name = [string]$payload.key
    if (-not $name) { Fail "缺少 key 参数" }
    $mode = [string]$payload.action
    if (-not $mode) { $mode = 'tap' }
    if ($mode -notin @('tap', 'down', 'up')) { Fail "未知 action: '$mode'（tap/down/up）" }
    $ms = Get-Int $payload.duration_ms 50
    if ($ms -lt 0) { $ms = 0 }
    if ($ms -gt 5000) { $ms = 5000 }
    $r = Send-Key $name $mode $ms
    Out-Json (@{ ok = $true } + $r)
  }

  'mouse' {
    $tool = [string]$payload.tool
    switch ($tool) {
      'mouse_move' {
        $hasAbs = ($null -ne $payload.x) -or ($null -ne $payload.y)
        $hasRel = ($null -ne $payload.dx) -or ($null -ne $payload.dy)
        if (-not $hasAbs -and -not $hasRel) { Fail "mouse_move 需要 x/y（绝对）或 dx/dy（相对）" }
        if ($hasAbs) {
          $pos = [GameCtlNative.Native]::MoveCursor((Get-Int $payload.x 0), (Get-Int $payload.y 0))
          Out-Json @{ ok = $true; mode = 'absolute'; x = $pos[0]; y = $pos[1] }
        } else {
          $dx = Get-Int $payload.dx 0; $dy = Get-Int $payload.dy 0
          $pos = [GameCtlNative.Native]::MoveCursorRelative($dx, $dy)
          Out-Json @{ ok = $true; mode = 'relative'; dx = $dx; dy = $dy; x = $pos[0]; y = $pos[1] }
        }
      }
      'mouse_click' {
        $button = [string]$payload.button
        if (-not $button) { $button = 'left' }
        $holdMs = Get-Int $payload.hold_ms 0
        if ($holdMs -gt 10000) { $holdMs = 10000 }
        Invoke-Click $button $payload.double $holdMs
        $pos = [GameCtlNative.Native]::CursorPos()
        Out-Json @{ ok = $true; button = $button; double = [bool]$payload.double; hold_ms = $holdMs
          x = $pos[0]; y = $pos[1] }
      }
      'mouse_wheel' {
        $delta = Get-Int $payload.delta 0
        if ($delta -eq 0) { Fail "wheel 需要 delta（120 = 一格）" }
        if ($null -ne $payload.x -and $null -ne $payload.y) {
          [void][GameCtlNative.Native]::MoveCursor((Get-Int $payload.x 0), (Get-Int $payload.y 0))
        }
        Invoke-Wheel $delta $payload.horizontal
        $pos = [GameCtlNative.Native]::CursorPos()
        Out-Json @{ ok = $true; delta = $delta; horizontal = [bool]$payload.horizontal; x = $pos[0]; y = $pos[1] }
      }
      default { Fail "未知鼠标工具: '$tool'" }
    }
  }

  'sequence' {
    $steps = @($payload.steps)
    if ($steps.Count -eq 0) { Fail "sequence 需要 steps 数组" }
    if ($steps.Count -gt 120) { Fail "steps 过多（上限 120）" }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $done = 0
    $executed = New-Object System.Collections.ArrayList
    foreach ($step in $steps) {
      if ($sw.ElapsedMilliseconds -gt 30000) {
        Out-Json @{ ok = $true; executed = $done; total = $steps.Count
          truncated = $true; elapsed_ms = $sw.ElapsedMilliseconds; note = '达到 30s 上限，序列提前结束' }
        exit 0
      }
      $op = [string]$step.op
      switch ($op) {
        'key' {
          $mode = [string]$step.mode
          if (-not $mode) { $mode = 'tap' }
          $ms = Get-Int $step.ms 30
          if ($ms -gt 5000) { $ms = 5000 }
          $r = Send-Key ([string]$step.key) $mode $ms
          [void]$executed.Add($r)
        }
        'wait' {
          $ms = Get-Int $step.ms 100
          if ($ms -lt 0) { $ms = 0 }
          if ($ms -gt 10000) { $ms = 10000 }
          Start-Sleep -Milliseconds $ms
          [void]$executed.Add(@{ op = 'wait'; ms = $ms })
        }
        'move' {
          if ($null -ne $step.x -or $null -ne $step.y) {
            $pos = [GameCtlNative.Native]::MoveCursor((Get-Int $step.x 0), (Get-Int $step.y 0))
            [void]$executed.Add(@{ op = 'move'; x = $pos[0]; y = $pos[1] })
          } else {
            $pos = [GameCtlNative.Native]::MoveCursorRelative((Get-Int $step.dx 0), (Get-Int $step.dy 0))
            [void]$executed.Add(@{ op = 'move'; dx = (Get-Int $step.dx 0); dy = (Get-Int $step.dy 0) })
          }
        }
        'click' {
          $button = [string]$step.button
          if (-not $button) { $button = 'left' }
          Invoke-Click $button $step.double (Get-Int $step.hold_ms 0)
          [void]$executed.Add(@{ op = 'click'; button = $button })
        }
        'wheel' {
          Invoke-Wheel (Get-Int $step.delta -120) $step.horizontal
          [void]$executed.Add(@{ op = 'wheel'; delta = (Get-Int $step.delta 0) })
        }
        default { throw "未知 step op: '$op'" }
      }
      $done++
    }
    Out-Json @{ ok = $true; executed = $done; total = $steps.Count
      truncated = $false; elapsed_ms = $sw.ElapsedMilliseconds; detail = @($executed.ToArray()) }
  }

  'windows' {
    $rows = [GameCtlNative.Native]::VisibleWindows()
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
      [void]$list.Add(@{
        hwnd = $row[0]; pid = $row[1]; title = $row[2]
        x = $row[3]; y = $row[4]; w = $row[5]; h = $row[6]
      })
    }
    Out-Json @{ ok = $true; count = $list.Count; windows = @($list.ToArray()) }
  }

  'focus' {
    $target = [IntPtr]::Zero
    if ($null -ne $payload.pid) {
      $wantPid = Get-Int $payload.pid -1
      $proc = Get-Process -Id $wantPid -ErrorAction SilentlyContinue
      if ($proc -and $proc.MainWindowHandle -ne 0) { $target = $proc.MainWindowHandle }
    } elseif ($payload.title) {
      $titleNeedle = [string]$payload.title
      $lower = $titleNeedle.ToLower()
      $best = $null
      foreach ($p in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })) {
        if ($p.MainWindowTitle -and $p.MainWindowTitle.ToLower().Contains($lower)) {
          if (-not $best -or $p.MainWindowTitle.Length -lt $best.MainWindowTitle.Length) { $best = $p }
        }
      }
      if ($best) { $target = $best.MainWindowHandle }
    } else {
      Fail "focus 需要 title 或 pid"
    }
    if ($target -eq [IntPtr]::Zero) { Fail "没找到匹配的窗口" }
    $ok = [GameCtlNative.Native]::ForceForeground($target)
    Start-Sleep -Milliseconds 80
    $ok = [GameCtlNative.Native]::GetForegroundWindow() -eq $target
    $rect = [GameCtlNative.Native]::WindowRect($target)
    $result = @{
      ok = $ok; hwnd = $target.ToInt64()
      x = $rect[0]; y = $rect[1]; w = $rect[2]; h = $rect[3]
    }
    if (-not $ok) {
      $result.note = 'SetForegroundWindow 未生效（Windows 前台锁），请重试或改用窗口化模式'
    }
    Out-Json $result
  }

  default { Fail "未知 Action: '$Action'" }
}
