local testing = require('testing_util')
return {
    engineHandlers = { onFrame = testing.makeUpdateMenu() },
    eventHandlers = testing.menuEventHandlers,
}
