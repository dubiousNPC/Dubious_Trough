---@omw-context player
local self   = require('openmw.self')
local common = require('scripts.show-all-weapons.common')

return {
    engineHandlers = {
        -- onUpdate, not onFrame. onFrame also runs while the game is paused,
        -- which is pointless here, and the two scripts used different handlers
        -- for identical work.
        onUpdate = common.makeUpdateHandler(self),
    }
}
