-- 노브 매크로 휠.
--
-- 노브를 돌리면 화면 가운데에 둥근 피커가 뜬다. 회전 한 칸마다 항목이 하나씩 넘어가고
-- 재생/일시정지로 확정하면 그 항목의 텍스트가 앞에 있는 앱에 들어간다. 이전 곡은 취소다.
-- 손을 멈춘 채 IDLE_TIMEOUT 이 지나면 아무것도 넣지 않고 조용히 닫힌다.
--
-- [왜 열릴 때마다 같은 자리에서 시작하나]
-- 인코더는 절대 위치를 주지 않는다. 지금 몇 번째 칸인지 장치는 모르고 방향만 보낸다.
-- 그래서 "한 칸이면 1번, 두 칸이면 2번"이 성립하려면 닫힐 때 선택을 버리고 다음에 열릴 때
-- 항상 1번부터 세야 한다. 홈은 화면에 그리지 않는 '선택 없음' 상태다. 반대로 돌려서 열면
-- 마지막 항목이 잡히므로 뒤쪽 항목도 한 칸 거리에 있다.
--
-- [끝에서 처음으로 돌아온다]
-- 둥근 피커니까 한 바퀴를 돌면 제자리다. 다섯 개를 등록했으면 여섯 칸째가 다시 1번이고
-- 반대로 돌리면 1번에서 마지막으로 넘어간다.
--
-- [붙여넣기를 쓰는 이유]
-- 한 글자씩 타이핑하면 한글 입력기가 켜져 있을 때 자모가 섞인다. 클립보드에 넣고 Cmd+V 를
-- 보내면 입력기를 타지 않고 긴 텍스트도 한 번에 들어간다. 원래 클립보드는 붙여넣기가 끝난
-- 뒤 되돌린다.

local M = {}

--- 등록된 매크로. 순서가 곧 칸 번호다.
---
---   short  조각에 찍히는 축약 이름
---   label  가운데에 찍히는 이름. 없으면 short 를 쓴다
---   text   확정했을 때 붙여넣을 텍스트
---
--- 항목을 더하거나 빼면 조각 수도 따라간다. 다만 순서를 바꾸면 손에 익은 칸 수가 어긋난다.
---
--- 기본값은 ~/.claude/history.jsonl 의 실제 입력 기록에서 골랐다(3,536건 중 슬래시 615건,
--- 2026-05-05 ~ 08-05). 고른 기준은 빈도가 아니라 '슬래시로만 되는가'다.
---
--- 스킬을 부르는 커맨드(/review, /commit, /pr, /happy-path 같은 것)는 말로 시키면 되고
--- /exit 은 Ctrl+C 두 번이면 되니 여기 둘 이유가 없다. 남는 것은 클라이언트가 하는 일 —
--- 세션 갈아타기, 인증, 한도, 플러그인 다시 불러오기 — 이고 이건 Claude 에게 말해도
--- 움직이지 않는다.
---
--- 1번과 마지막 칸이 한 칸 거리이므로 제일 자주 쓰는 둘을 양 끝에 두었다.
--- 붙여넣은 뒤 커서를 세울 자리 표시. 텍스트 안에 한 번 끼워 넣으면 붙여넣기가 끝난 뒤
--- 그 자리까지 왼쪽 화살표로 되돌아간다. 화면에 찍히지 않는 제어문자라 본문과 겹치지 않는다.
local CARET = "\1"

--- 여기 있는 것은 기본값일 뿐이다. 쓰는 목록은 init.lua 에서 통째로 갈아 끼운다 — 사내
--- 문구나 사람 이름이 든 상용구는 이 레포가 공개라 여기에 두지 않는다.
M.macros = {
  { short = "새 세션", label = "/new", text = "/new" }, -- /clear 까지 합쳐 79회·20일
  { short = "플러그인", label = "/reload-plugins", text = "/reload-plugins" }, -- 22회·11일, 15자
  { short = "이어서", label = "/resume", text = "/resume" }, -- 32회·14일
}

--- 직접 만든 상용구에도 커서 자리를 넣을 수 있게 열어 둔다.
---
---   text = "안녕하세요 " .. knobMapping.wheel.caret .. " 건으로 연락드립니다"
M.caret = CARET

local IDLE_TIMEOUT = 4 -- 회전이 끊긴 뒤 저절로 닫히기까지의 시간
local RESTORE_DELAY = 0.4 -- 붙여넣기 뒤 원래 클립보드를 되돌리기까지 기다리는 시간
-- 커서를 되돌리기 전에 기다리는 시간. 붙여넣기를 비동기로 처리하는 앱(브라우저 안의 JIRA)
-- 에서는 화살표가 글자보다 먼저 도착할 수 있다
local CARET_DELAY = 0.15

local look = {
  outerRadius = 148,
  innerRadius = 68, -- 가운데 구멍. 여기에 고른 항목의 전체 이름이 들어간다
  padding = 10,
  sliceGap = 1.2, -- 조각 사이를 벌리는 각도
  labelRadius = 105, -- 축약 이름을 놓는 반지름
}

local color = {
  panel = { white = 0.09, alpha = 0.93 },
  hub = { white = 0.09, alpha = 1.0 }, -- 가운데는 불투명해야 뒤 조각이 비치지 않는다
  slice = { white = 0.24, alpha = 0.95 },
  sliceOn = { red = 0.22, green = 0.55, blue = 0.98, alpha = 1.0 },
  text = { white = 0.72, alpha = 1.0 },
  textOn = { white = 1.0, alpha = 1.0 },
  center = { white = 0.97, alpha = 1.0 },
  index = { white = 0.45, alpha = 1.0 },
}

local canvas = nil
local selected = nil -- nil 이면 닫힌 상태
local idleTimer = nil

--- canvas 의 arc 는 12시가 0도이고 시계 방향으로 커진다. 조각과 글자가 같은 규칙을 써야
--- 서로 어긋나지 않으므로 좌표 계산도 여기 한 곳에 둔다.
local function pointOnCircle(centre, radius, degrees)
  local rad = math.rad(degrees)
  return centre + radius * math.sin(rad), centre - radius * math.cos(rad)
end

local function canvasSize()
  return 2 * (look.outerRadius + look.padding)
end

local function ensureCanvas()
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local area = screen:fullFrame()
  local size = canvasSize()
  local frame = {
    x = area.x + (area.w - size) / 2,
    y = area.y + (area.h - size) / 2,
    w = size,
    h = size,
  }

  if canvas then
    canvas:frame(frame)
  else
    canvas = hs.canvas.new(frame)
    canvas:level(hs.canvas.windowLevels.overlay)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:clickActivating(false)
  end
  return canvas
end

--- 페이드를 쓰지 않는 이유. hide(fade) 로 사라진 canvas 는 alpha 가 0 으로 남고 다음
--- show(fade) 가 그걸 되돌리지 않는다. 실측하면 요소 14개가 다 들어 있는 canvas 가
--- isShowing=true, alpha=0.0 인 채로 화면에 아무것도 그리지 않았다. 매번 알파를 직접
--- 세우고 즉시 띄운다. 칸을 세는 물건이라 즉시 뜨는 편이 손에도 맞는다.
local function present()
  local target = ensureCanvas()
  target:alpha(1.0)
  target:show()
end

local function draw()
  local macros = M.macros
  local count = #macros
  if count == 0 or not selected then
    return
  end

  local centre = canvasSize() / 2
  local step = 360 / count
  -- 1번을 12시에 놓고 시계 방향으로 세운다. 조각 하나가 통째로 원이면 틈이 필요 없다
  local gap = (count > 1) and look.sliceGap or 0

  local elements = {
    {
      type = "circle",
      action = "fill",
      center = { x = centre, y = centre },
      radius = look.outerRadius + look.padding,
      fillColor = color.panel,
    },
  }

  for index, macro in ipairs(macros) do
    local mid = (index - 1) * step
    local on = index == selected

    elements[#elements + 1] = {
      type = "arc",
      action = "fill",
      center = { x = centre, y = centre },
      radius = look.outerRadius,
      startAngle = mid - step / 2 + gap,
      endAngle = mid + step / 2 - gap,
      arcRadii = true,
      fillColor = on and color.sliceOn or color.slice,
    }

    local x, y = pointOnCircle(centre, look.labelRadius, mid)
    elements[#elements + 1] = {
      type = "text",
      text = macro.short or macro.label or macro.text,
      textSize = 13,
      textFont = ".AppleSystemUIFont",
      textColor = on and color.textOn or color.text,
      textAlignment = "center",
      frame = { x = x - 44, y = y - 18, w = 88, h = 36 },
    }
  end

  elements[#elements + 1] = {
    type = "circle",
    action = "fill",
    center = { x = centre, y = centre },
    radius = look.innerRadius,
    fillColor = color.hub,
  }

  local chosen = macros[selected]
  elements[#elements + 1] = {
    type = "text",
    text = chosen.label or chosen.short or chosen.text,
    textSize = 15,
    textFont = ".AppleSystemUIFont",
    textColor = color.center,
    textAlignment = "center",
    frame = { x = centre - 66, y = centre - 20, w = 132, h = 24 },
  }
  elements[#elements + 1] = {
    type = "text",
    text = string.format("%d / %d", selected, count),
    textSize = 11,
    textFont = ".AppleSystemUIFont",
    textColor = color.index,
    textAlignment = "center",
    frame = { x = centre - 40, y = centre + 6, w = 80, h = 18 },
  }

  ensureCanvas():replaceElements(table.unpack(elements))
end

local function stopIdleTimer()
  if idleTimer then
    idleTimer:stop()
    idleTimer = nil
  end
end

local function restartIdleTimer()
  stopIdleTimer()
  idleTimer = hs.timer.doAfter(IDLE_TIMEOUT, function()
    idleTimer = nil
    M.cancel()
  end)
end

local function close()
  stopIdleTimer()
  selected = nil
  if canvas then
    canvas:hide()
  end
end

--- 클립보드에 넣고 Cmd+V 로 밀어 넣은 뒤 원래 내용을 되돌린다.
---
--- 되돌리기 전에 지금 클립보드가 여전히 우리가 넣은 값인지 확인한다. 그 사이 사용자가
--- 다른 것을 복사했다면 그건 우리가 덮을 물건이 아니다.
local function paste(text)
  -- 커서 자리 표시가 있으면 빼내고, 그 뒤에 남는 글자 수만큼 나중에 왼쪽으로 되돌아간다.
  -- 화살표는 글자 단위로 움직이므로 바이트가 아니라 코드포인트로 세야 한다
  local caretAt = text:find(CARET, 1, true)
  local back = 0
  if caretAt then
    text = text:sub(1, caretAt - 1) .. text:sub(caretAt + #CARET)
    back = utf8.len(text, caretAt) or 0
  end

  local saved = hs.pasteboard.readAllData()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v")

  if back > 0 then
    hs.timer.doAfter(CARET_DELAY, function()
      for _ = 1, back do
        hs.eventtap.keyStroke({}, "left", 0)
      end
    end)
  end

  hs.timer.doAfter(RESTORE_DELAY, function()
    if hs.pasteboard.getContents() ~= text then
      return
    end
    if saved and next(saved) then
      hs.pasteboard.writeAllData(saved)
    else
      hs.pasteboard.clearContents()
    end
  end)
end

--- 노브 한 칸. direction 은 시계 방향이 1, 반시계가 -1 이다.
function M.step(direction)
  local count = #M.macros
  if count == 0 then
    return
  end

  if selected then
    -- 한 바퀴를 돌면 제자리다. 마지막에서 한 칸 더 가면 1번, 1번에서 반대로 가면 마지막
    selected = (selected - 1 + direction) % count + 1
  else
    -- 닫힌 상태에서의 첫 회전. 시계 방향이면 1번, 반시계면 마지막
    selected = direction > 0 and 1 or count
  end

  draw()
  present()
  restartIdleTimer()
end

--- 고른 항목을 붙여넣고 닫는다. 열려 있지 않았으면 아무것도 하지 않고 false 를 준다.
function M.commit()
  if not selected then
    return false
  end
  local chosen = M.macros[selected]
  close()
  if chosen then
    paste(chosen.text)
  end
  return true
end

--- 아무것도 넣지 않고 닫는다.
function M.cancel()
  if not selected then
    return false
  end
  close()
  return true
end

function M.isOpen()
  return selected ~= nil
end

--- 화면에서 완전히 치운다. knob_mapping 을 멈출 때 같이 불린다.
function M.stop()
  stopIdleTimer()
  selected = nil
  if canvas then
    canvas:delete()
    canvas = nil
  end
end

return M
