---@omw-context none
--[[
    caravans_stops.lua -- which travel stop is this position at?

    WHY PLACES ARE FOUND BY POSITION, NOT BY NAME

    The guide's travel destinations come from the NPC record as
    { cellId, position }. For an exterior destination cellId is an engine id,
    not "Balmora", so it never matched a route key, and every destination
    was dropped from the menu. Positions do not depend on cell naming, id
    format, or which mod renamed a region, so both the origin (the guide's own
    position) and each destination are resolved to the nearest route stop.

    STOP CENTRES ARE MEDIANS

    A stop's centre is the median x and median y of every route endpoint
    labelled with it. A mean would be dragged by a mislabelled file, and the
    source has one: suran_balmora ends ~47500 units from Balmora, where
    the other six Balmora endpoints agree to within ~1500.

    BAD ROUTES ARE DROPPED, SO THE REVERSE IS USED

    A route whose start or end is not at its named stop would put the player
    down somewhere other than the place they paid for. validate() removes it,
    and findRoute's reverse fallback then uses the well-formed opposite
    direction (balmora_suran in that case).

    Numbers, measured 2026-10-28 on the shipped data: the closest two
    distinct stop centres (suran, vivec) are ~31000 apart, and the worst good
    endpoint is ~13000 from its centre (hlan oek -> almas thirr). RADIUS sits
    between them, so a position can never be within reach of two stops.
]]

local M = {}

M.RADIUS = 15000

local function median(list)
    table.sort(list)
    local n = #list
    if n % 2 == 1 then return list[(n + 1) / 2] end
    return (list[n / 2] + list[n / 2 + 1]) / 2
end

---Centre of every stop named by the routes table, as { key = {x, y} }.
function M.centres(routes)
    local xs, ys = {}, {}
    local function add(key, x, y)
        xs[key] = xs[key] or {}
        ys[key] = ys[key] or {}
        table.insert(xs[key], x)
        table.insert(ys[key], y)
    end
    for from, dests in pairs(routes) do
        for to, p in pairs(dests) do
            -- Empty source files ship as empty arrays; they say nothing
            -- about where either stop is.
            if #p >= 6 then
                add(from, p[1], p[2])
                add(to, p[#p - 2], p[#p - 1])
            end
        end
    end
    local out = {}
    for key, list in pairs(xs) do
        out[key] = { median(list), median(ys[key]) }
    end
    return out
end

local function dist(c, x, y)
    local dx, dy = c[1] - x, c[2] - y
    return math.sqrt(dx * dx + dy * dy)
end

---Remove, in place, every route whose ends are not at its named stops.
---Returns a list of "from -> to (reason)" strings for the caller to report.
function M.validate(routes, centres)
    local dropped = {}
    for from, dests in pairs(routes) do
        for to, p in pairs(dests) do
            local why
            if #p < 6 then
                why = 'empty'
            elseif dist(centres[from], p[1], p[2]) > M.RADIUS then
                why = string.format('starts %.0f from %s',
                    dist(centres[from], p[1], p[2]), from)
            elseif dist(centres[to], p[#p - 2], p[#p - 1]) > M.RADIUS then
                why = string.format('ends %.0f from %s',
                    dist(centres[to], p[#p - 2], p[#p - 1]), to)
            end
            if why then
                dests[to] = nil
                table.insert(dropped, from .. ' -> ' .. to .. ' (' .. why .. ')')
            end
        end
    end
    table.sort(dropped)
    return dropped
end

---The stop at (x, y), or nil when none is within RADIUS.
function M.at(centres, x, y)
    local best, bestD
    for key, c in pairs(centres) do
        local d = dist(c, x, y)
        if d <= M.RADIUS and (not bestD or d < bestD) then
            best, bestD = key, d
        end
    end
    return best
end

return M
