local ffi = require("ffi")
local android = require("android")
local BB = require("ffi/blitbuffer")
local C = ffi.C

--[[ configuration for devices with an electric paper display controller ]]--

-- does the device has an e-ink screen?
local has_eink_screen, eink_platform = android.isEink()
local has_hisense_present_barrier = has_eink_screen
    and type(eink_platform) == "string"
    and eink_platform:match("^hisense%-a7") ~= nil

-- does the device needs to handle all screen refreshes
local has_eink_full_support = android.isEinkFull()


local full, partial, full_ui, partial_ui, fast, delay_page, delay_ui, delay_fast = android.getEinkConstants()

local framebuffer = {}

-- update a region of the screen
function framebuffer:_updatePartial(mode, delay, x, y, w, h)
    local bb = self.full_bb or self.bb
    x, y, w, h = bb:getBoundedRect(x, y, w, h)
    x, y, w, h = bb:getPhysicalRect(x, y, w, h)

    android.einkUpdate(mode, delay, x, y, (x + w), (y + h))
end

-- update the entire screen
function framebuffer:_updateFull()
    if eink_platform == "rockchip" then
        android.einkUpdate(full)
    else
        self:_updatePartial(full, delay_page, 0, 0, self:getWidth(), self:getHeight())
    end
end

function framebuffer:init()
    -- we present this buffer to the outside
    self.bb = BB.new(android.screen.width, android.screen.height, BB.TYPE_BBRGB32)
    self.bb:fill(BB.COLOR_WHITE)
    self:_updateWindow()
    framebuffer.parent.init(self)
end

-- resize on rotation or split view.
function framebuffer:resize()
    android.screen.width = android.getScreenWidth()
    android.screen.height = android.getScreenHeight()
    local rotation
    local inverse
    if self.bb then
        rotation = self.bb:getRotation()
        inverse = self.bb:getInverse() == 1
        self.bb:free()
    end
    self.bb = BB.new(android.screen.width, android.screen.height, BB.TYPE_BBRGB32)

    -- Rotation and inverse must be inherited
    if rotation then
        self.bb:setRotation(rotation)
    end
    if inverse then
        self.bb:invert()
    end

    self.bb:fill(inverse and BB.COLOR_BLACK or BB.COLOR_WHITE)
    self:_updateWindow()
end

function framebuffer:getRotationMode()
    if android.hasNativeRotation() then
        return android.orientation.get()
    else
        return self.cur_rotation_mode
    end
end

function framebuffer:setRotationMode(mode)
    if android.hasNativeRotation() then
        local key
        if mode == 0 then key = "PORTRAIT"
        elseif mode == 1 then key = "LANDSCAPE"
        elseif mode == 2 then key = "REVERSE_PORTRAIT"
        elseif mode == 3 then key = "REVERSE_LANDSCAPE" end
        if key then
            android.orientation.set(C["ASCREEN_ORIENTATION_" .. key])
        end
    else
        framebuffer.parent.setRotationMode(self, mode)
    end
end

function framebuffer:_updateWindow()
    if android.app.window == nil then
        android.LOGW("cannot blit: no window")
        return
    end

    local buffer = ffi.new("ANativeWindow_Buffer[1]")
    if android.lib.ANativeWindow_lock(android.app.window, buffer, nil) < 0 then
        android.LOGW("Unable to lock window buffer")
        return
    end

    local bb = nil
    if buffer[0].format == C.WINDOW_FORMAT_RGBA_8888
    or buffer[0].format == C.WINDOW_FORMAT_RGBX_8888
    then
        bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB32, buffer[0].bits, buffer[0].stride*4, buffer[0].stride)
    elseif buffer[0].format == C.WINDOW_FORMAT_RGB_565 then
        bb = BB.new(buffer[0].width, buffer[0].height, BB.TYPE_BBRGB16, buffer[0].bits, buffer[0].stride*2, buffer[0].stride)
    else
        android.LOGE("unsupported window format!")
    end

    if bb then
        local ext_bb = self.full_bb or self.bb
        -- Rotations and inverse are applied in the base ffi/framebuffer class, so our shadow buffer is already inverted and rotated.
        -- All we need is to do is simply clone the invert and rotation settings, so that the blit below becomes 1:1 copy.
        bb:setInverse(ext_bb:getInverse())
        bb:setRotation(ext_bb:getRotation())

        -- getUseCBB should *always* be true on Android, but let's be thorough...
        if bb:getInverse() == 1 and BB:getUseCBB() then
            -- If we're using the CBB (which we should), the invert flag has been thoroughly ignored up until now,
            -- so, simply invert everything *now* ;).
            -- The idea is that we absolutely want to avoid the Lua BB on Android, because it is *extremely* erratic,
            -- because of the mcode alloc issues...

            -- NOTE: CBB's invertblitFrom requires source & dest bb to be of the same type!
            if bb:getType() == ext_bb:getType() then
                -- In practice, this means RGB32, because our self.bb is always RGB32 (c.f., init above)
                bb:invertblitFrom(ext_bb)
            else
                -- On ther other hand, if the window buffer is RGB565, things become uglier...
                bb:blitFrom(ext_bb)
                -- Fair warning, this is inaccurate for anything that isn't pure black or white on RGB565 ;).
                bb:invertRect(0, 0, bb:getWidth(), bb:getHeight())
            end
        else
            bb:blitFrom(ext_bb)
        end
    end

    local posted_frame_id
    if has_hisense_present_barrier and android.getNextWindowFrameId then
        local frame_id, rc = android.getNextWindowFrameId()
        if frame_id ~= nil then
            posted_frame_id = frame_id
        else
            android.LOGW(string.format("Hisense A7 native present frame-id capture failed rc=%s", tostring(rc)))
        end
    end

    local post_rc = android.lib.ANativeWindow_unlockAndPost(android.app.window)
    if post_rc < 0 then
        android.LOGW(string.format("ANativeWindow_unlockAndPost failed rc=%d", post_rc))
        return
    end
    return posted_frame_id
end

function framebuffer:refreshFullImp(x, y, w, h) -- luacheck: ignore
    if has_eink_screen and eink_platform == "huawei" then
        self:_updateFull()
        self:_updateWindow()
    else
        local frame_id = self:_updateWindow()
        if has_eink_screen then
            if has_hisense_present_barrier and frame_id ~= nil and android.waitWindowDisplayPresent then
                local rc, present_ns = android.waitWindowDisplayPresent(frame_id, 100)
                if rc == 0 then
                    android.LOGI(string.format(
                        "Hisense A7 frame barrier PASS kind=present-fence frame=%s present_ns=%s",
                        tostring(frame_id), tostring(present_ns)
                    ))
                elseif rc == 1 then
                    android.LOGI(string.format(
                        "Hisense A7 frame barrier PASS kind=post-composite-no-fence frame=%s present_ns=%s",
                        tostring(frame_id), tostring(present_ns)
                    ))
                else
                    android.LOGW(string.format(
                        "Hisense A7 frame barrier failed rc=%s frame=%s present_ns=%s; forcing clear as fallback",
                        tostring(rc), tostring(frame_id), tostring(present_ns)
                    ))
                end
            end
            self:_updateFull()
        end
    end
end

function framebuffer:refreshPartialImp(x, y, w, h)
    if has_eink_screen and eink_platform == "huawei" then
        self:_updatePartial(partial, delay_page, x, y, w, h)
        self:_updateWindow()
    else
        self:_updateWindow()
        if has_eink_full_support then
            self:_updatePartial(partial, delay_page, x, y, w, h)
        end
    end
end

function framebuffer:refreshFlashPartialImp(x, y, w, h)
    if has_eink_screen and eink_platform == "huawei" then
        self:_updatePartial(full, delay_page, x, y, w, h)
        self:_updateWindow()
    else
        self:_updateWindow()
        if has_eink_full_support then
            self:_updatePartial(full, delay_page, x, y, w, h)
        end
    end
end

function framebuffer:refreshUIImp(x, y, w, h)
    if has_eink_screen and eink_platform == "huawei" then
        self:_updatePartial(partial_ui, delay_ui, x, y, w, h)
        self:_updateWindow()
    else
        self:_updateWindow()
        if has_eink_full_support then
            self:_updatePartial(partial_ui, delay_ui, x, y, w, h)
        end
    end
end

function framebuffer:refreshFlashUIImp(x, y, w, h)
    if has_eink_screen and eink_platform == "huawei" then
        self:_updatePartial(full_ui, delay_ui, x, y, w, h)
        self:_updateWindow()
    else
        self:_updateWindow()
        if has_eink_full_support then
            self:_updatePartial(full_ui, delay_ui, x, y, w, h)
        end
    end
end

function framebuffer:refreshFastImp(x, y, w, h)
    if has_eink_screen and eink_platform == "huawei" then
        self:_updatePartial(fast, delay_fast, x, y, w, h)
        self:_updateWindow()
    else
        self:_updateWindow()
        if has_eink_full_support then
            self:_updatePartial(fast, delay_fast, x, y, w, h)
        end
    end
end

return require("ffi/framebuffer"):extend(framebuffer)
