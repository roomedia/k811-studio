-- 노브/버튼이 실제로 어떤 이벤트를 보내는지 기록하는 학습용 모듈.
-- 이벤트를 소비하지 않으므로(return false) 캡처 중에도 볼륨/재생 등 원래 동작은 그대로 유지된다.
-- 매핑 확정 후에는 init.lua 에서 require 를 제거하면 된다.

local M = {}

local logPath = os.getenv("HOME") .. "/.hammerspoon/knob_capture.log"

local function append(line)
  local f = io.open(logPath, "a")
  if f then
    f:write(string.format("%.3f  %s\n", hs.timer.secondsSinceEpoch(), line))
    f:close()
  end
end

-- systemDefined: 미디어 키(볼륨/재생/이전곡/다음곡)가 여기로 들어온다
local systemTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(e)
  local sys = e:systemKey()
  if sys and sys.key then
    append(string.format(
      "SYSTEM  key=%-10s down=%-5s repeat=%-5s",
      tostring(sys.key), tostring(sys.down), tostring(sys["repeat"])
    ))
  end
  return false
end)

-- 일반 키보드 키로 들어오는 경우(노브가 키보드 HID 로 잡히는 저가형 매크로패드)
local keyTap = hs.eventtap.new(
  { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp },
  function(e)
    local code = e:getKeyCode()
    local name = hs.keycodes.map[code] or "?"
    local dir = (e:getType() == hs.eventtap.event.types.keyDown) and "down" or "up"
    local mods = {}
    for m in pairs(e:getFlags()) do
      table.insert(mods, m)
    end
    table.sort(mods)
    append(string.format(
      "KEY     code=%-4d name=%-12s %-4s mods=[%s]",
      code, name, dir, table.concat(mods, ",")
    ))
    return false
  end
)

-- 노브가 스크롤 휠로 들어오는 경우
local scrollTap = hs.eventtap.new({ hs.eventtap.event.types.scrollWheel }, function(e)
  append(string.format(
    "SCROLL  dy=%s dx=%s",
    tostring(e:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)),
    tostring(e:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis2))
  ))
  return false
end)

function M.start()
  local f = io.open(logPath, "a")
  if f then
    f:write("\n===== capture start =====\n")
    f:close()
  end
  systemTap:start()
  keyTap:start()
  scrollTap:start()
  hs.alert.show("노브 캡처 시작")
end

function M.stop()
  systemTap:stop()
  keyTap:stop()
  scrollTap:stop()
  hs.alert.show("노브 캡처 중지")
end

M.logPath = logPath

return M
