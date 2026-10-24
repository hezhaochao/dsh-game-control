# dsh-game-control — 真实输入端到端测试（仅限本机/Windows CI 交互会话）
#
# 由 backend.tests.ps1 在 GAMECTL_E2E=1 时调用；也会被 npm run test:backend 间接运行。
# 内容：
#   1. 鼠标相对位移往返（移过去再移回来，落点必须还原）
#   2. 扫描码按键注入：spawn 一个等待按键的 choice.exe 控制台，聚焦它，
#      发送扫描码 "b"，若 choice 立即返回 "B" 则证明合成扫描码到达了真实程序
#   3. 截图 + 窗口列表冒烟
# 全部动作无破坏性：鼠标最终归位，choice 进程用完即退。
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$backend = Join-Path $repoRoot 'scripts\gamectl.ps1'

function Invoke-Backend([string]$action, [string]$json) {
  # JSON 走环境变量：-File 传参会被 PS 5.1 吃掉内层引号（真机踩坑）
  $env:GAMECTL_JSON = $json
  try {
    $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $backend -Action $action
    $text = ($raw | Out-String).Trim()
    return $text | ConvertFrom-Json
  } finally {
    Remove-Item Env:GAMECTL_JSON -ErrorAction SilentlyContinue
  }
}

$failures = 0
function Assert-True([bool]$cond, [string]$name) {
  if ($cond) {
    Write-Output "PASS $name"
  } else {
    Write-Output "FAIL $name"
    $script:failures++
  }
}

# ── 1. 截图冒烟 ──────────────────────────────────────────────
$shot = Invoke-Backend 'screenshot' '{}'
Assert-True ($shot.ok -and (Test-Path -LiteralPath $shot.path) -and $shot.width -gt 0) "screenshot 生成 PNG（$($shot.width)x$($shot.height)）"

# ── 2. 鼠标相对位移（人在用电脑时会干扰位置断言，因此只验证接受与归位） ──
$before = Invoke-Backend 'pos' '{}'
$moved = Invoke-Backend 'mouse' '{"tool":"mouse_move","dx":120,"dy":60}'
Assert-True ($moved.ok -and $moved.mode -eq 'relative') "mouse_move relative 被接受"
# 用绝对移动把指针送回原位（SetCursorPos，确定性强）
$restored = Invoke-Backend 'mouse' (@{ tool = 'mouse_move'; x = $before.x; y = $before.y } | ConvertTo-Json -Compress)
$after = Invoke-Backend 'pos' '{}'
Assert-True ($restored.ok -and $after.x -eq $before.x -and $after.y -eq $before.y) "指针已用绝对移动归位（$($after.x),$($after.y)）"

# ── 3. 扫描码按键注入（choice.exe 端到端） ────────────────────
$work = Join-Path $env:TEMP 'gamectl-e2e'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$outFile = Join-Path $work 'choice.txt'
Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
# choice /c BA：只接受 B 或 A；/t 20 秒后默认 A。收到扫描码 B 则立刻输出 B。
$proc = Start-Process cmd.exe -ArgumentList "/c choice /c BA /n /t 20 /d A > `"$outFile`" 2>&1" -PassThru -WindowStyle Minimized
Start-Sleep -Milliseconds 900
$focused = Invoke-Backend 'focus' (@{ pid = $proc.Id } | ConvertTo-Json -Compress)
$pressed = Invoke-Backend 'key' '{"key":"b","action":"tap","duration_ms":40}'
Start-Sleep -Milliseconds 300
$exited = $proc.WaitForExit(26000)
$answer = if (Test-Path -LiteralPath $outFile) { (Get-Content -LiteralPath $outFile -Raw).Trim() } else { '' }
Assert-True ($focused.ok -eq $true) "focus 聚焦 choice 控制台窗口"
Assert-True ($pressed.ok -and $pressed.scan -eq 48) "key 发送扫描码 b=0x30（48）"
Assert-True ($exited -and $answer -eq 'B') "扫描码注入端到端：choice 收到 B（返回 '$answer'）"

# ── 4. 窗口列表冒烟 ──────────────────────────────────────────
$wins = Invoke-Backend 'windows' '{}'
Assert-True ($wins.ok -and $wins.count -gt 0) "windows 列出 $($wins.count) 个可见窗口"

Write-Output ""
if ($failures -gt 0) {
  Write-Output "E2E RESULT: $failures 项失败"
  exit 1
}
Write-Output "E2E RESULT: 全部通过"
