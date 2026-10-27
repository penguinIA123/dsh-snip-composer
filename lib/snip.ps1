# snip.ps1 —— 截图提问内核（下拉菜单版，无选择窗）
# 由 dsh-snip-composer 的 POST /_dsh/snip-composer/capture 调用。
# 参数 -Mode：
#   region       框选屏幕区域（默认）
#   fullscreen   截取整个虚拟屏幕（多显示器合并）
#   hide-region  先隐藏 DSH 窗口再框选
#   diag         诊断模式：不弹窗，抓两张全屏图 + 报告 DPI 缩放比（排障用）
# 流程：切 Per-Monitor-V2 DPI -> （可选隐藏 DSH）-> 框选/全屏截图
#       -> 把 PNG 写成临时文件（imagePath），由 Node 读回归 base64，浏览器端
#          用 DataTransfer + ClipboardEvent 派发 paste，100% 可靠、不依赖全局焦点、
#          也不污染系统剪贴板。图片留在对话框，等用户输入后发送 -> 输出 JSON
param([string]$Mode = 'region')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class SnipWin {
  public delegate bool EnumDelegate(IntPtr h, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumDelegate lp, IntPtr l);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int nCmdShow);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
  [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int nIndex);
  [DllImport("gdi32.dll")] public static extern bool BitBlt(IntPtr hdc, int x, int y, int cx, int cy, IntPtr hdcSrc, int x1, int y1, uint rop);

  // DESKTOPHORZRES = 118, DESKTOPVERTRES = 117 —— 这两个返回**物理**像素尺寸，
  // 与 SystemInformation.VirtualScreen（DPI 虚拟化后的逻辑尺寸）对比即可算出缩放比。
  public static int PhysW() { IntPtr dc = GetDC(IntPtr.Zero); int v = GetDeviceCaps(dc, 118); ReleaseDC(IntPtr.Zero, dc); return v; }
  public static int PhysH() { IntPtr dc = GetDC(IntPtr.Zero); int v = GetDeviceCaps(dc, 117); ReleaseDC(IntPtr.Zero, dc); return v; }

  public static IntPtr FindByTitle(string sub) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(new EnumDelegate((h, lp) => {
      if (!IsWindowVisible(h)) return true;
      StringBuilder sb = new StringBuilder(256);
      GetWindowText(h, sb, 256);
      if (sb.ToString().IndexOf(sub, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
      return true;
    }), IntPtr.Zero);
    return found;
  }

  public static void EnablePerMonitorDpi() {
    try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch {}
  }

  public static string ForegroundTitle() {
    IntPtr h = GetForegroundWindow();
    StringBuilder sb = new StringBuilder(256);
    GetWindowText(h, sb, 256);
    return sb.ToString();
  }

  public static void ForceForeground(IntPtr h) {
    uint pid = 0;
    uint fgTid = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
    uint myTid = GetCurrentThreadId();
    bool attached = false;
    if (fgTid != 0 && fgTid != myTid) { attached = AttachThreadInput(myTid, fgTid, true); }
    ShowWindow(h, 9); // SW_RESTORE
    SetForegroundWindow(h);
    if (attached) { AttachThreadInput(myTid, fgTid, false); }
  }
}
'@

$ErrorActionPreference = 'Stop'
$result = @{ ok = $true; mode = $Mode }
$dshHwnd = [IntPtr]::Zero
$hideDsh = ($Mode -eq 'hide-region')
$isDiag  = ($Mode -eq 'diag')
$cancelled = $false

# 诊断图输出目录（工作区，可写）
$diagDir = 'C:\Users\36072\Documents\deepseek-harness\default-workspace'

function Capture-Physical([int]$px, [int]$py, [int]$pw, [int]$ph, [string]$tag) {
  # 用 BitBlt + CAPTUREBLT(0x40000000) 抓物理像素。
  # .NET 的 Graphics.CopyFromScreen 只带 SRCCOPY，抓不到部分硬件加速/分层窗口，
  # 且它按逻辑坐标取，DPI 非 100% 时位置会整体偏移。
  $bmp = New-Object Drawing.Bitmap($pw, $ph)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  $sdc = [SnipWin]::GetDC([IntPtr]::Zero)
  $ok = [SnipWin]::BitBlt($hdc, 0, 0, $pw, $ph, $sdc, $px, $py, [uint32]0x40CC0020)
  [void][SnipWin]::ReleaseDC([IntPtr]::Zero, $sdc)
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  if ($tag) {
    try { $bmp.Save((Join-Path $diagDir $tag), [Drawing.Imaging.ImageFormat]::Png) } catch { }
  }
  return @{ bmp = $bmp; ok = $ok }
}

try {
  # 关键：必须在创建任何窗口之前切到 Per-Monitor-V2，否则框选坐标与截图坐标错位
  [SnipWin]::EnablePerMonitorDpi()

  # 先拿 DSH 窗口句柄（隐藏后 IsWindowVisible 会变 false，之后找不到）
  $dshHwnd = [SnipWin]::FindByTitle("DeepSeek Harness")

  # ---------- 诊断模式：不弹窗，抓全屏 + 报告缩放比 ----------
  if ($isDiag) {
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    $pw = [SnipWin]::PhysW()
    $ph = [SnipWin]::PhysH()
    $result.logical  = "$($vs.Width)x$($vs.Height)"
    $result.physical = "${pw}x${ph}"
    $result.scaleX   = [Math]::Round($pw / $vs.Width, 4)
    $result.scaleY   = [Math]::Round($ph / $vs.Height, 4)
    $result.fg       = [SnipWin]::ForegroundTitle()

    # A: 旧的 CopyFromScreen（逻辑坐标）
    try {
      $bA = New-Object Drawing.Bitmap($vs.Width, $vs.Height)
      $gA = [Drawing.Graphics]::FromImage($bA)
      $gA.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $vs.Size)
      $gA.Dispose()
      $bA.Save((Join-Path $diagDir 'diag-A-copyfromscreen.png'), [Drawing.Imaging.ImageFormat]::Png)
      $bA.Dispose()
      $result.a = 'ok'
    } catch { $result.a = 'FAIL: ' + $_.Exception.Message }

    # B: BitBlt + CAPTUREBLT（物理坐标）
    $cap = Capture-Physical $vs.Left $vs.Top $pw $ph 'diag-B-bitblt.png'
    $result.b = if ($cap.ok) { 'ok' } else { 'bitblt-returned-false' }
    $cap.bmp.Dispose()
    [Console]::Out.Write((ConvertTo-Json $result -Compress))
    exit 0
  }

  # ---------- 可选：隐藏 DSH 界面 ----------
  if ($hideDsh -and $dshHwnd -ne [IntPtr]::Zero) {
    [SnipWin]::ShowWindow($dshHwnd, 0) | Out-Null   # SW_HIDE
    Start-Sleep -Milliseconds 400
  }

  if ($Mode -eq 'fullscreen') {
    # ---------- 全屏：截整个虚拟屏幕（含多显示器）----------
    # 用物理像素尺寸，避免 DPI 缩放导致只截到左上角一块
    $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    $pw = [SnipWin]::PhysW()
    $ph = [SnipWin]::PhysH()
    $cap = Capture-Physical $vs.Left $vs.Top $pw $ph ''
    $bmp = $cap.bmp
  } else {
    # ---------- 框选：全屏覆盖层拖选 ----------
    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.WindowState = 'Maximized'
    $form.TopMost = $true
    $form.BackColor = 'Black'
    $form.Opacity = 0.33
    $form.Cursor = 'Cross'
    $form.KeyPreview = $true
    $form.ShowInTaskbar = $false

    $script:start = $null
    $script:rect = $null
    $script:pen = New-Object Drawing.Pen([Drawing.Color]::White, 4)

    $form.Add_MouseDown({ param($s,$e) if ($e.Button -eq 'Left') { $script:start = $e.Location; $script:rect = New-Object Drawing.Rectangle($e.X, $e.Y, 0, 0) } })
    $form.Add_MouseMove({ param($s,$e) if ($script:start) { $x=[Math]::Min($script:start.X,$e.X); $y=[Math]::Min($script:start.Y,$e.Y); $w=[Math]::Abs($e.X-$script:start.X); $h=[Math]::Abs($e.Y-$script:start.Y); $script:rect = New-Object Drawing.Rectangle($x,$y,$w,$h); $form.Invalidate() } })
    $form.Add_Paint({ param($s,$pe) if ($script:rect -and $script:rect.Width -gt 0) { $pe.Graphics.DrawRectangle($script:pen, $script:rect) } })
    $form.Add_MouseUp({ param($s,$e) if ($script:rect -and $script:rect.Width -gt 5 -and $script:rect.Height -gt 5) { $form.DialogResult = 'OK' } else { $form.DialogResult = 'Cancel' } })
    $form.Add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Escape') { $form.DialogResult = 'Cancel' } })

    $res = $form.ShowDialog()

    if ($res -ne 'OK' -or -not $script:rect -or $script:rect.Width -le 5) {
      $form.Dispose()
      $cancelled = $true
    } else {
      $rect = $script:rect
      $form.Hide()
      [Windows.Forms.Application]::DoEvents()
      Start-Sleep -Milliseconds 150

      # 关键修复：拖框得到的是**逻辑**坐标，BitBlt 需要**物理**像素坐标。
      # 缩放比 = 物理屏宽 / 逻辑屏宽（150% 缩放下为 1.5）。不换算会导致：
      # 截图内容偏移、只截到桌面一角、或当前台是其他应用时抓到空白。
      $vs2 = [Windows.Forms.SystemInformation]::VirtualScreen
      $sx = [SnipWin]::PhysW() / $vs2.Width
      $sy = [SnipWin]::PhysH() / $vs2.Height
      $result.scaleX = [Math]::Round($sx, 4)
      $result.scaleY = [Math]::Round($sy, 4)
      $result.rectLogical = "$($rect.X),$($rect.Y) $($rect.Width)x$($rect.Height)"

      $px = [int][Math]::Round($rect.X * $sx)
      $py = [int][Math]::Round($rect.Y * $sy)
      $pw = [int][Math]::Round($rect.Width * $sx)
      $ph = [int][Math]::Round($rect.Height * $sy)
      $result.rectPhysical = "$px,$py ${pw}x${ph}"

      $cap = Capture-Physical $px $py $pw $ph ''
      $bmp = $cap.bmp
      $result.bitblt = $cap.ok
      $form.Dispose()
    }
  }

  if (-not $cancelled) {
    # 新方案（修复「只有第一次能自动粘贴」bug1）：不再依赖系统剪贴板 + 全局焦点，
    # 而是把 PNG 写成临时文件，由 Node 读回归 base64，浏览器端用 DataTransfer +
    # ClipboardEvent 派发 paste，走 DSH 自己的 paste 通道插入图片。
    # 好处：① 100% 可靠，不依赖全局焦点态（旧 SendKeys ^v 第一次成、之后丢根因）；
    #       ② 图片不进系统剪贴板，天然不会污染/残留（即满足 bug2 的清空需求）。
    try {
      # 临时目录：用户本地 TEMP（可写），用 GUID 避免碰撞
      $tmpDir = $env:TEMP
      if (-not (Test-Path $tmpDir)) { $tmpDir = [System.IO.Path]::GetTempPath() }
      $fileName = "snip-composer-" + [Guid]::NewGuid().ToString('N') + ".png"
      $imagePath = Join-Path $tmpDir $fileName
      $bmp.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png)
      $result.imagePath = $imagePath
      $result.pasted = $false   # 真正的“粘贴”由浏览器端派发 paste 完成
      $result.delivered = $true # 图片已写到临时文件，等待客户端取走
    } catch {
      $result.ok = $false
      $result.error = 'write temp png failed: ' + $_.Exception.Message
    }
    # 注意：不再调用 ForceForeground / SetImage / SendKeys，DSH 窗口保持原样即可。
  }
} catch {
  $result.ok = $false
  $result.error = $_.Exception.Message
} finally {
  # 无论取消/异常/成功，都恢复 DSH（hide-region 模式曾隐藏它）
  if ($hideDsh -and $dshHwnd -ne [IntPtr]::Zero) {
    try { [SnipWin]::ShowWindow($dshHwnd, 5) | Out-Null } catch { }   # SW_SHOW
    # 仅 hide-region 模式：截图完成后自动把 DSH 切回前台（SW_RESTORE + 置顶），
    # 省去用户手动切回窗口。其他模式不调用，行为不变。
    if (-not $cancelled) {
      try { [SnipWin]::ForceForeground($dshHwnd) | Out-Null } catch { }
    }
  }
}

if ($cancelled) { $result.ok = $false; $result.reason = 'cancelled' }

[Console]::Out.Write((ConvertTo-Json $result -Compress))
