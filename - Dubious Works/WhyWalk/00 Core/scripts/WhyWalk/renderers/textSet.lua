---@diagnostic disable: missing-fields, redundant-return-value
---@omw-context menu
--[[
    textSet.lua -- a free-form add/remove set of strings, as a settings widget

    VENDORED, NOT A DEPENDENCY.

    From Bor's Drop-in Utils (https://github.com/OpenMW-Mod-Collection/DropinUtils),
    which is explicitly a collection of files to copy into your own project
    rather than a mod to depend on: "Free to use, modify and redistribute. No
    permissions required, but a mention of the project is appreciated."
    Consider it mentioned -- this renderer is the whole reason the creature
    blacklist is a usable list instead of a comma-separated string, and its
    own README example is a creature blacklist.

    Same arrangement as SharedRay: bundled, so WhyWalk gains no dependency and
    works with or without the upstream collection installed.

    THE REGISTERED KEY IS SCOPED TO WhyWalk, and that is a deliberate
    departure from upstream.

    Upstream registers `textSet_V1`. The version suffix is the same trick
    AnimRefresh uses so several mods can ship one file and the newest wins --
    but AnimRefresh can do that because it has an interface to check
    (`if I.AnimRefresh and I.AnimRefresh.version >= MY_VERSION then return`).
    A renderer has nothing to query: I.Settings offers registerRenderer and no
    way to ask what is already registered, and the API documents nothing about
    registering a key twice. So two mods vendoring this file would both
    register `textSet_V1` with unknown results.

    `whywalk_textSet_V1` cannot collide with anything, including the real
    DropinUtils if the player also has it installed. The cost is not sharing
    one implementation of a 173-line widget, which is a smaller price than an
    untestable load-order hazard.

    Only the registered key and this header differ from upstream. If you are
    updating from upstream, keep both.
]]
local I = require("openmw.interfaces")
local ui = require("openmw.ui")
local async = require("openmw.async")

-- ============================================================================
-- textSet renderer — a free-form, add/remove set of strings (e.g. an ID list)
-- ============================================================================
-- USAGE (settings config entry):
--   {
--      key = 'MY_BLACKLIST',
--      name = 'Blacklist NPC by ID',
--      description = 'Add NPC IDs to the blacklist.',
--      renderer = 'textSet',
--      default = {
--         ["caius cosades"] = true,
--         ["guar"] = true,
--         ["vivec"] = true,
--      },
--      argument = {
--         lower = true,   -- OPTIONAL, default: false. Default values don't get lowercased automatically
--      },
--   },
--
-- RESULTING STORED VALUE:
--   { ["caius cosades"] = true, ["guar"] = true, ["vivec"] = true }
-- ============================================================================


---@class TextSetArgs
---@field lower? boolean    OPTIONAL, Default: false
---                         If true, all input text will be lowered.
---                         It does not lower your default values due to how Lua API works.

I.Settings.registerRenderer('whywalk_textSet_V1', function(input, set, arg)
    ---@type TextSetArgs
    arg = arg or {}
    local lower = arg.lower == true

    if not input then
        input = {}
        set(input)
    end

    local header = {
        type = ui.TYPE.Flex,
        props = {
            horizontal = true,
        },
        content = ui.content({}),
        external = {
            stretch = 1,
        },
    }

    local inputText = ''

    header.content:add {
        template = I.MWUI.templates.box,
        content = ui.content { {
            template = I.MWUI.templates.padding,
            content = ui.content { {
                template = I.MWUI.templates.textNormal,
                props = {
                    text = "Add",
                },
                events = {
                    mouseClick = async:callback(function()
                        -- no empty strings allowed
                        if inputText == "" then return end

                        -- no duplicates allowed (map key already true)
                        if input[inputText] then
                            set(input)
                            return
                        end

                        input[inputText] = true
                        set(input)
                    end),
                },
            } }
        } },
    }
    header.content:add {
        template = I.MWUI.templates.padding,
        external = {
            grow = 1,
        },
    }
    header.content:add {
        template = I.MWUI.templates.box,
        content = ui.content { {
            template = I.MWUI.templates.padding,
            content = ui.content { {
                template = I.MWUI.templates.textEditLine,
                events = {
                    textChanged = async:callback(function(text)
                        inputText = lower
                            and text:lower()
                            or text
                    end),
                } },
            } },
        },
    }

    local body = {
        type = ui.TYPE.Flex,
        content = ui.content({}),
    }

    local function remove(text)
        input[text] = nil
    end

    local sortedKeys = {}
    for text in pairs(input) do
        table.insert(sortedKeys, text)
    end
    table.sort(sortedKeys)

    for _, text in ipairs(sortedKeys) do
        body.content:add {
            template = I.MWUI.templates.padding,
        }
        body.content:add {
            type = ui.TYPE.Flex,
            props = {
                horizontal = true,
                arrange = ui.ALIGNMENT.Center,
            },
            content = ui.content {
                {
                    template = I.MWUI.templates.box,
                    content = ui.content { {
                        template = I.MWUI.templates.padding,
                        content = ui.content { {
                            template = I.MWUI.templates.textNormal,
                            props = {
                                text = "x",
                                textAlignV = ui.ALIGNMENT.Center,
                            },
                            events = {
                                mouseClick = async:callback(function()
                                    remove(text)
                                    set(input)
                                end),
                            },
                        } },
                    } },
                },
                {
                    template = I.MWUI.templates.padding,
                },
                {
                    template = I.MWUI.templates.textNormal,
                    props = { text = text },
                },
            },
        }
    end

    return {
        type = ui.TYPE.Flex,
        content = ui.content {
            header,
            body,
        },
    }
end)
