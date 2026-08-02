-- 노브/버튼 → 마우스 동작 매핑.
--
-- 입력은 Karabiner-Elements 가 노브 장치(YJS MicroChip 0x5566/0x000A)에서만 골라
-- f16~f20 으로 바꿔 보내준다. Hammerspoon 은 이벤트의 출처 장치를 알 수 없어서
-- 장치 필터는 Karabiner 쪽이 담당한다.
--
--   f16 = 노브 반시계    f17 = 노브 시계
--   f18 = 이전 곡        f19 = 다음 곡      f20 = 재생/일시정지
--
-- 동작:
--   노브 반시계/시계        → 마우스 좌/우 STEP px 이동
--   이전 곡 / 다음 곡       → 좌클릭 / 우클릭
--   재생/일시정지 (짧게)    → 휠(가운데) 클릭
--   재생/일시정지 + 노브    → 마우스 위/아래 STEP px 이동
--
-- [세로 이동을 '창'으로 처리하는 이유]
-- 이 장치는 consumer HID 리포트에 usage 를 한 번에 하나만 담는다. 그래서 노브를 돌리면
-- 재생/일시정지가 하드웨어적으로 강제 release 된다(관측값: 회전 13ms 전에 key up).
-- 버튼을 실제로 누르고 있는지 알 방법이 없으므로, 버튼을 뗀 직후 COMBO_WINDOW 안에
-- 노브가 들어오면 조합으로 보고 세로 모드에 진입한다. 세로 모드는 회전이 이어지는 동안
-- VERTICAL_IDLE 만큼 계속 연장되고, 손을 멈추면 가로로 돌아온다.

local M = {}

local STEP = 100 -- 한 스텝 이동 픽셀
local COMBO_WINDOW = 0.15 -- 버튼을 뗀 뒤 이 시간 안에 노브가 오면 조합으로 본다
local VERTICAL_IDLE = 1.0 -- 세로 모드가 회전 없이 유지되는 시간
local LONG_PRESS = 0.7 -- 이보다 오래 눌렀다 떼면 휠 클릭 없이 조합 의도로만 본다
local CLICK_DELAY = 0.15 -- 휠 클릭을 미루는 시간. 이 사이 노브가 오면 취소된다

local KEYS = {
  knobCCW = "f16",
  knobCW = "f17",
  prevBtn = "f18",
  nextBtn = "f19",
  playBtn = "f20",
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
end

local function onPlayUp()
  local t = now()
  local held = pressedAt and (t - pressedAt) or 0
  pressedAt = nil

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
  pressedAt = nil
  verticalUntil = 0
end

M.keys = KEYS

return M
