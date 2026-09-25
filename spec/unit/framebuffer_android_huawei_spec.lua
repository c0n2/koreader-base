describe("Huawei Android framebuffer refresh ordering", function()
    local source

    setup(function()
        local f = assert(io.open("ffi/framebuffer_android.lua", "r"))
        source = f:read("*a")
        f:close()
    end)

    it("posts the new framebuffer before requesting a full refresh", function()
        local function_start = assert(
            source:find(
                "function framebuffer:refreshFullImp",
                1,
                true
            )
        )

        local huawei_start = assert(
            source:find(
                'if has_eink_screen and eink_platform == "huawei" then',
                function_start,
                true
            )
        )

        local else_start = assert(
            source:find(
                "    else",
                huawei_start,
                true
            )
        )

        local huawei_branch =
            source:sub(huawei_start, else_start - 1)

        local post_pos = assert(
            huawei_branch:find(
                "self:_updateWindow()",
                1,
                true
            )
        )

        local full_pos = assert(
            huawei_branch:find(
                "self:_updateFull()",
                1,
                true
            )
        )

        assert.is_true(post_pos < full_pos)
    end)
end)
