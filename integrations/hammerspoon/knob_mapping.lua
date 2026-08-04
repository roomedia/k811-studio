-- 노브/조이스틱/버튼 → 마우스 동작 매핑.
--
-- 입력은 두 갈래로 들어온다.
--
--   미디어 키·노브: Karabiner-Elements 가 노브 장치(YJS MicroChip 0x5566/0x000A)에서만
--   골라 f16~f20 으로 바꿔 보내준다. Hammerspoon 은 이벤트의 출처 장치를 알 수 없어서
--   장치 필터는 Karabiner 쪽이 담당한다.
--
--     f16 = 노브 반시계    f17 = 노브 시계
--     f18 = 이전 곡        f19 = 다음 곡      f20 = 재생/일시정지
--
--   조이스틱: 장치가 방향마다 화살표 키를 그대로 낸다(usage 0x4F~0x52). 번역이 필요 없어서
--   Karabiner 를 거치지 않고 여기서 직접 받는다.
--
-- 동작:
--   노브 반시계/시계        → 마우스 좌/우 STEP px 이동
--   이전 곡 / 다음 곡       → 좌클릭 / 우클릭
--   재생/일시정지 (짧게)    → 휠(가운데) 클릭
--   재생/일시정지 + 노브    → 마우스 위/아래 STEP px 이동
--   재생/일시정지 + 조이스틱 → 커서 미세 이동. 누르고 있는 동안만
--
-- [세로 이동을 '창'으로 처리하는 이유]
-- 이 장치는 consumer HID 리포트에 usage 를 한 번에 하나만 담는다. 그래서 노브를 돌리면
-- 재생/일시정지가 하드웨어적으로 강제 release 된다(관측값: 회전 13ms 전에 key up).
-- 버튼을 실제로 누르고 있는지 알 방법이 없으므로, 버튼을 뗀 직후 COMBO_WINDOW 안에
-- 노브가 들어오면 조합으로 보고 세로 모드에 진입한다. 세로 모드는 회전이 이어지는 동안
-- VERTICAL_IDLE 만큼 계속 연장되고, 손을 멈추면 가로로 돌아온다.
--
-- [조이스틱은 왜 창이 필요 없나]
-- 화살표는 consumer 가 아닌 키보드 리포트로 오기 때문에 재생/일시정지를 밀어내지 않는다.
-- 실측하면 버튼을 누른 채 조이스틱을 네 방향으로 움직여도 f20 key up 은 손을 뗄 때 한 번만
-- 온다. 그래서 버튼이 눌려 있는지를 그대로 믿고 hold 모드로 쓴다.
--
--   258.274  f20 down          ← 버튼 누름
--   258.564  up  down          ← 조이스틱, f20 은 그대로 눌려 있음
--   260.212  down up
--   260.368  f20 up            ← 손을 뗄 때 처음 올라온다
--
-- 조이스틱은 밀고 있는 동안 33ms 간격으로 auto-repeat 를 내고 놓을 때 key up 을 준다.
-- 다만 이동은 repeat 에 얹지 않고 자체 타이머로 만든다. repeat 간격은 시스템 키보드 설정에
-- 따라 달라지므로 커서 속도가 그걸 따라가면 안 된다.

local M = {}

local STEP = 100 -- 노브 한 스텝 이동 픽셀
local COMBO_WINDOW = 0.15 -- 버튼을 뗀 뒤 이 시간 안에 노브가 오면 조합으로 본다
local VERTICAL_IDLE = 1.0 -- 세로 모드가 회전 없이 유지되는 시간
local LONG_PRESS = 0.7 -- 이보다 오래 눌렀다 떼면 휠 클릭 없이 조합 의도로만 본다
local CLICK_DELAY = 0.15 -- 휠 클릭을 미루는 시간. 이 사이 노브가 오면 취소된다

local JOY_TICK = 1 / 60 -- 커서를 다시 그리는 간격
local JOY_NUDGE = 2 -- 딸깍 한 번에 움직일 픽셀
local JOY_HOLD_DELAY = 0.12 -- 이 시간을 넘겨 밀고 있으면 활주로 넘어간다
local JOY_MIN_SPEED = 2 -- 활주 시작 속도 (tick 당 픽셀)
local JOY_MAX_SPEED = 18 -- 활주 최고 속도 (tick 당 픽셀)
local JOY_RAMP = 0.6 -- 최고 속도까지 걸리는 시간
local DIAGONAL = 0.7071 -- 대각선일 때 축별 속도 보정

local KEYS = {
  knobCCW = "f16",
  knobCW = "f17",
  prevBtn = "f18",
  nextBtn = "f19",
  playBtn = "f20",
  joyUp = "up",
  joyDown = "down",
  joyLeft = "left",
  joyRight = "right",
}

-- 논리 이름 → 조이스틱 방향. 여기 있는 것만 hold 모드에서 커서를 움직인다
local JOY_AXIS = {
  joyUp = "up",
  joyDown = "down",
  joyLeft = "left",
  joyRight = "right",
}

-- keycode → 논리 이름 역매핑
local byCode = {}
for name, keyName in pairs(KEYS) do
  local code = hs.keycodes.map[keyName]
  if code then
    byCode[code] = name
  else
    hs.printf("knob_mapping: 알 수 없는 키 이름 %s", keyName)
  end
end

local pressedAt = nil -- 재생/일시정지를 누른 시각
local verticalUntil = 0 -- 이 시각 전까지 들어온 노브는 세로 이동
local pendingClick = nil -- 미뤄둔 휠 클릭 타이머

local playHeld = false -- 재생/일시정지가 눌려 있는가
local joyHeld = { up = false, down = false, left = false, right = false }
local joyTimer = nil -- 활주 타이머
local joyPressedAt = 0 -- 이번 밀기가 시작된 시각
local joyUsed = false -- 이번 버튼 누름에서 조이스틱을 썼는가
local joyConsumed = {} -- key down 을 먹은 방향. key up 도 같이 먹어야 한다

local function now()
  return hs.timer.secondsSinceEpoch()
end

local function moveBy(dx, dy)
  local p = hs.mouse.absolutePosition()
  hs.eventtap.event.newMouseEvent(
    hs.eventtap.event.types.mouseMoved,
    { x = p.x + dx, y = p.y + dy }
  ):post()
end

local function cancelPendingClick()
  if pendingClick then
    pendingClick:stop()
    pendingClick = nil
  end
end

-- MARK: - 조이스틱 활주

local function joyVector()
  local dx = (joyHeld.right and 1 or 0) - (joyHeld.left and 1 or 0)
  local dy = (joyHeld.down and 1 or 0) - (joyHeld.up and 1 or 0)
  return dx, dy
end

local function joyStop()
  if joyTimer then
    joyTimer:stop()
    joyTimer = nil
  end
end

--- 밀고 있는 동안 커서를 계속 움직인다. 처음 JOY_HOLD_DELAY 는 쉰다.
---
--- 딸깍 한 번은 key down 의 nudge 로 이미 끝났으므로, 그 시간을 넘겨 계속 밀고 있을 때만
--- 활주로 넘어간다. 그래서 짧게 톡 치면 JOY_NUDGE 픽셀만 움직이고 길게 밀면 가속된다.
local function joyTick()
  local dx, dy = joyVector()
  if dx == 0 and dy == 0 then
    joyStop()
    return
  end

  local gliding = now() - joyPressedAt - JOY_HOLD_DELAY
  if gliding <= 0 then
    return
  end

  local ratio = math.min(gliding / JOY_RAMP, 1)
  -- 제곱 곡선. 시작은 느리게 두고 끝에서 붙는다
  local speed = JOY_MIN_SPEED + (JOY_MAX_SPEED - JOY_MIN_SPEED) * ratio * ratio
  if dx ~= 0 and dy ~= 0 then
    speed = speed * DIAGONAL
  end
  moveBy(dx * speed, dy * speed)
end

local function onJoyDown(axis)
  if joyHeld[axis] then
    return -- auto-repeat. 이동은 타이머가 만든다
  end
  joyHeld[axis] = true
  joyUsed = true
  cancelPendingClick() -- 조이스틱을 썼으면 이 누름은 휠 클릭이 아니다

  local dx, dy = joyVector()
  if dx ~= 0 or dy ~= 0 then
    local nudge = (dx ~= 0 and dy ~= 0) and JOY_NUDGE * DIAGONAL or JOY_NUDGE
    moveBy(dx * nudge, dy * nudge)
  end

  if not joyTimer then
    joyPressedAt = now()
    joyTimer = hs.timer.doEvery(JOY_TICK, joyTick)
  end
end

local function onJoyUp(axis)
  joyHeld[axis] = false
  local dx, dy = joyVector()
  if dx == 0 and dy == 0 then
    joyStop()
  end
end

local function joyReleaseAll()
  for axis in pairs(joyHeld) do
    joyHeld[axis] = false
  end
  joyStop()
end

-- MARK: - 노브와 버튼

local function onKnob(direction)
  local t = now()
  if t < verticalUntil then
    -- 조합으로 판정. 예약된 휠 클릭이 있으면 취소하고 세로 모드를 연장한다
    cancelPendingClick()
    verticalUntil = t + VERTICAL_IDLE
    moveBy(0, direction * STEP)
  else
    moveBy(direction * STEP, 0)
  end
end

local function onPlayDown(isRepeat)
  if isRepeat then
    -- 길게 누를 때 오는 자동 반복. 최초 누름 시각을 유지한다
    return
  end
  cancelPendingClick()
  pressedAt = now()
  playHeld = true
  joyUsed = false
end

local function onPlayUp()
  local t = now()
  local held = pressedAt and (t - pressedAt) or 0
  pressedAt = nil
  playHeld = false
  joyReleaseAll()

  if joyUsed then
    -- 조이스틱으로 커서를 옮긴 누름이다. 휠 클릭도, 노브 조합도 아니다
    joyUsed = false
    return
  end

  -- 노브 회전 때문에 강제로 떼진 것일 수 있으므로 항상 조합 창을 연다
  verticalUntil = t + COMBO_WINDOW

  if held <= LONG_PRESS then
    -- 짧게 눌렀다 뗀 경우만 휠 클릭 후보. 창 안에 노브가 오면 취소된다
    pendingClick = hs.timer.doAfter(CLICK_DELAY, function()
      pendingClick = nil
      hs.eventtap.middleClick(hs.mouse.absolutePosition())
    end)
  end
end

local tap = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
  function(e)
    local logical = byCode[e:getKeyCode()]
    if not logical then
      return false
    end

    local isDown = e:getType() == hs.eventtap.event.types.keyDown
    local isRepeat = isDown and e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0

    local axis = JOY_AXIS[logical]
    if axis then
      -- 버튼을 누르지 않았으면 화살표는 화살표다. 이 탭은 출처 장치를 모르므로
      -- 여기서 삼키면 모든 키보드의 화살표가 같이 죽는다
      if isDown then
        if not playHeld then
          return false
        end
        joyConsumed[axis] = true
        onJoyDown(axis)
      else
        -- key down 을 먹었으면 짝이 되는 key up 도 먹어야 한다. 버튼을 먼저 뗐더라도
        -- 앱에 key up 만 남겨두면 그 앱은 화살표가 계속 눌려 있다고 본다
        if not joyConsumed[axis] then
          return false
        end
        joyConsumed[axis] = nil
        onJoyUp(axis)
      end
      return true
    end

    if logical == "knobCCW" then
      if isDown then
        onKnob(-1)
      end
    elseif logical == "knobCW" then
      if isDown then
        onKnob(1)
      end
    elseif logical == "prevBtn" then
      if isDown and not isRepeat then
        hs.eventtap.leftClick(hs.mouse.absolutePosition())
      end
    elseif logical == "nextBtn" then
      if isDown and not isRepeat then
        hs.eventtap.rightClick(hs.mouse.absolutePosition())
      end
    elseif logical == "playBtn" then
      if isDown then
        onPlayDown(isRepeat)
      else
        onPlayUp()
      end
    end

    return true -- f16~f20 은 다른 앱으로 흘려보내지 않는다
  end
)

function M.start()
  tap:start()
end

function M.stop()
  tap:stop()
  cancelPendingClick()
  joyReleaseAll()
  joyConsumed = {}
  playHeld = false
  joyUsed = false
  pressedAt = nil
  verticalUntil = 0
end

M.keys = KEYS

return M
