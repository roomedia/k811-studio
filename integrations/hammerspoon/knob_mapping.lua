-- 노브/조이스틱/버튼 → 매크로 휠과 마우스 동작 매핑.
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
--   노브 반시계/시계         → 매크로 휠. 한 칸에 한 항목 (macro_wheel.lua)
--   이전 곡 / 다음 곡        → 좌클릭 / 우클릭
--   재생/일시정지 (짧게)     → 휠(가운데) 클릭
--   재생/일시정지 + 조이스틱 → 커서 미세 이동. 누르고 있는 동안만
--
-- 매크로 휠이 열려 있는 동안에만 두 버튼의 뜻이 바뀐다. 재생/일시정지는 확정이고 이전 곡은
-- 취소다. 휠이 닫혀 있으면 원래대로 휠 클릭과 좌클릭이다. 키보드 엔터와 esc 도 휠이 열려
-- 있는 동안만 확정·취소로 가로챈다.
--
-- [노브가 더는 커서를 움직이지 않는 이유]
-- 예전에는 노브가 커서를 가로로 옮기고 재생 버튼과 조합하면 세로로 옮겼다. 조이스틱 미세
-- 이동이 생기면서 둘 다 조이스틱이 더 잘하게 됐고, 세로 조합은 애초에 정확해질 수 없는
-- 판정이었다. 이 장치는 consumer HID 리포트에 usage 를 한 번에 하나만 담아서 노브를 돌리면
-- 재생/일시정지가 하드웨어적으로 강제 release 된다(관측값: 회전 5~13ms 전에 key up). 버튼을
-- 실제로 누르고 있는지 알 방법이 없으니 버튼을 뗀 직후 짧은 창 안에 노브가 들어오면 조합으로
-- 치는 수밖에 없었고, 그 창은 좁힐 수만 있고 정확해질 수는 없었다. 노브를 매크로 휠에
-- 넘기면서 창 판정과 그것을 위해 미뤄두던 휠 클릭까지 통째로 걷어냈다.
--
-- [조이스틱은 왜 강제 release 를 겪지 않나]
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

local wheel = require('macro_wheel')

local M = {}

-- 조이스틱을 쓰려다 만 누름은 휠 클릭이 아니다. 이보다 오래 눌렀다 떼면 클릭하지 않는다.
local LONG_PRESS = 0.7

local DIAGONAL = 0.7071 -- 대각선일 때 축별 속도 보정

-- 조이스틱 이동 감각. 손끝에 맞추는 값이라 M.tune 으로 돌아가는 중에도 바꿀 수 있다.
local joy = {
  tick = 1 / 60, -- 커서를 다시 그리는 간격. 바꾸면 다음 밀기부터 적용된다
  nudge = 2, -- 딸깍 한 번에 움직일 픽셀
  holdDelay = 0.12, -- 이 시간을 넘겨 밀고 있으면 활주로 넘어간다
  minSpeed = 1, -- 활주 시작 속도 (tick 당 픽셀)
  maxSpeed = 8, -- 활주 최고 속도 (tick 당 픽셀)
  ramp = 0.5, -- 최고 속도까지 걸리는 시간
  curve = 1.5, -- 붙는 곡선. 1 이면 직선이고 크면 초반이 느려진다
}

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
  wheelEnter = "return",
  wheelPadEnter = "padenter",
  wheelEscape = "escape",
  -- 이 환경은 init.lua 에서 escape 를 f13 으로 remap 해 두었다. 실제 esc 키는 f13 으로
  -- 들어오므로 둘 다 잡는다. remap 을 걷어냈다면 이 줄은 지워도 된다
  wheelEscapeRemap = "f13",
}

-- 매크로 휠이 열려 있는 동안에만 가로채는 키보드 키. 닫혀 있으면 손대지 않는다.
--
-- 이 탭은 출처 장치를 모르니 본 키보드의 엔터와 esc 도 같이 먹는다. 휠은 화면을 덮고
-- 뜨는 모달이라 그게 맞는 동작이다. 다만 f13 은 다른 용도가 걸려 있으므로 휠이 닫혀
-- 있는 동안에는 반드시 흘려보내야 한다.
local WHEEL_ACTION = {
  wheelEnter = "commit",
  wheelPadEnter = "commit",
  wheelEscape = "cancel",
  wheelEscapeRemap = "cancel",
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

local playHeld = false -- 재생/일시정지가 눌려 있는가
local playToWheel = false -- 이번 재생 버튼 누름을 매크로 휠이 먹었는가
local joyHeld = { up = false, down = false, left = false, right = false }
local joyTimer = nil -- 활주 타이머
local joyPressedAt = 0 -- 이번 밀기가 시작된 시각
local joyUsed = false -- 이번 버튼 누름에서 조이스틱을 썼는가
local joyConsumed = {} -- key down 을 먹은 방향. key up 도 같이 먹어야 한다
local wheelConsumed = {} -- 휠이 먹은 엔터·esc. key up 도 같이 먹어야 한다

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

--- 밀고 있는 동안 커서를 계속 움직인다. 처음 joy.holdDelay 는 쉰다.
---
--- 딸깍 한 번은 key down 의 nudge 로 이미 끝났으므로, 그 시간을 넘겨 계속 밀고 있을 때만
--- 활주로 넘어간다. 그래서 짧게 톡 치면 joy.nudge 픽셀만 움직이고 길게 밀면 가속된다.
local function joyTick()
  local dx, dy = joyVector()
  if dx == 0 and dy == 0 then
    joyStop()
    return
  end

  local gliding = now() - joyPressedAt - joy.holdDelay
  if gliding <= 0 then
    return
  end

  local ratio = math.min(gliding / joy.ramp, 1) ^ joy.curve
  local speed = joy.minSpeed + (joy.maxSpeed - joy.minSpeed) * ratio
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

  local dx, dy = joyVector()
  if dx ~= 0 or dy ~= 0 then
    local nudge = (dx ~= 0 and dy ~= 0) and joy.nudge * DIAGONAL or joy.nudge
    moveBy(dx * nudge, dy * nudge)
  end

  if not joyTimer then
    joyPressedAt = now()
    joyTimer = hs.timer.doEvery(joy.tick, joyTick)
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

-- MARK: - 버튼

local function onPlayDown(isRepeat)
  if isRepeat then
    -- 길게 누를 때 오는 자동 반복. 최초 누름 시각을 유지한다
    return
  end
  pressedAt = now()
  playHeld = true
  joyUsed = false
end

local function onPlayUp()
  local held = pressedAt and (now() - pressedAt) or 0
  pressedAt = nil
  playHeld = false
  joyReleaseAll()

  if joyUsed then
    -- 조이스틱으로 커서를 옮긴 누름이다. 휠 클릭이 아니다
    joyUsed = false
    return
  end

  if held <= LONG_PRESS then
    hs.eventtap.middleClick(hs.mouse.absolutePosition())
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

    local wheelAction = WHEEL_ACTION[logical]
    if wheelAction then
      -- 휠이 닫혀 있으면 엔터는 엔터고 esc 는 esc 다. 단 down 을 먹었으면 그 뒤에 휠이
      -- 닫혔더라도 짝이 되는 up 까지 먹는다
      if not wheel.isOpen() and not wheelConsumed[logical] then
        return false
      end
      if isDown then
        wheelConsumed[logical] = true
        if not isRepeat then
          if wheelAction == "commit" then
            wheel.commit()
          else
            wheel.cancel()
          end
        end
      else
        wheelConsumed[logical] = nil
      end
      return true
    end

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
        wheel.step(-1)
      end
    elseif logical == "knobCW" then
      if isDown then
        wheel.step(1)
      end
    elseif logical == "prevBtn" then
      if isDown and not isRepeat then
        -- 휠이 열려 있으면 취소, 아니면 좌클릭
        if not wheel.cancel() then
          hs.eventtap.leftClick(hs.mouse.absolutePosition())
        end
      end
    elseif logical == "nextBtn" then
      if isDown and not isRepeat then
        hs.eventtap.rightClick(hs.mouse.absolutePosition())
      end
    elseif logical == "playBtn" then
      -- 휠을 확정한 누름은 key up 까지 먹는다. 남겨두면 onPlayUp 이 휠 클릭을 낸다
      if isDown then
        if not isRepeat and wheel.commit() then
          playToWheel = true
        elseif not playToWheel then
          onPlayDown(isRepeat)
        end
      elseif playToWheel then
        playToWheel = false
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
  wheel.stop()
  joyReleaseAll()
  joyConsumed = {}
  wheelConsumed = {}
  playHeld = false
  playToWheel = false
  joyUsed = false
  pressedAt = nil
end

--- 조이스틱 이동 감각을 돌아가는 중에 바꾼다. 손끝에 맞출 때는 파일을 고치고
--- 다시 불러들이는 것보다 이쪽이 빠르다. 마음에 드는 값은 위 joy 표에 옮겨 적을 것.
---
---   hs -c "knobMapping.tune{ maxSpeed = 6, ramp = 1.5 }"
---   hs -c "hs.inspect(knobMapping.tune{})"
function M.tune(values)
  for key, value in pairs(values or {}) do
    if joy[key] == nil then
      hs.printf("knob_mapping: 알 수 없는 조이스틱 값 %s", tostring(key))
    else
      joy[key] = value
    end
  end
  return joy
end

M.keys = KEYS

--- 매크로 표를 바깥에서 손볼 수 있게 열어 둔다.
---
---   hs -c "hs.inspect(knobMapping.wheel.macros)"
M.wheel = wheel

return M
