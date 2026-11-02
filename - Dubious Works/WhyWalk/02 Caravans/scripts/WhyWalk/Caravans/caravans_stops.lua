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

-- A STRAY POINT IN THE MIDDLE OF A ROUTE
--
-- The endpoint checks above only look at where a route starts and ends.
-- `vivec -> seyda neen` passes both and is still unusable: at point 29 of 37
-- it turns 178 degrees, runs 73,468 units out and comes straight back. Of its
-- 204,146-unit "length", 145,392 is that one out-and-back spike -- it is not
-- the longest route in the data, it is a broken one. In game the strider
-- turned round halfway and trudged away for the best part of two minutes,
-- which reads exactly like being stuck.
--
-- The test is a segment grossly out of scale with the rest of its own route,
-- which is what a pair of stray points looks like. Measured over all 47
-- shipped routes, longest segment divided by median segment:
--
--     vivec -> seyda neen   50.5     <- corrupt
--     suran -> balmora      27.0     <- corrupt (the endpoint check already
--                                       catches this one, from the other end)
--     seyda neen -> vivec    6.7     <- worst well-formed route
--     bosmora -> sailen      4.7
--     ...
--     molag ruhn region      1.5
--
-- 10 sits in the gap: 1.5x above the worst good route and 2.7x below the
-- better of the two bad ones. A ratio, not an absolute length, because
-- segment scale varies legitimately between routes (median 1329 to 2364).
--
-- Tortuosity (total length over straight-line distance) separates these two
-- as well, 4.84 against 1.50, but it would also condemn a genuinely winding
-- mountain road. The outlier test names what is actually wrong.
M.MAX_SEGMENT_RATIO = 10

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

---The longest segment of a flat {x,y,z,...} route over its median segment,
---plus the length and index of that segment. 0 for a route too short to have
---two segments to compare.
---
---Used by validate; exported because the importer wants the same number.
---@return number ratio, number longest, number index 1-based segment index
function M.segmentOutlier(p)
    local n = math.floor(#p / 3)
    if n < 3 then return 0, 0, 0 end
    local lens = {}
    for i = 2, n do
        local a, b = (i - 2) * 3, (i - 1) * 3
        local dx = p[b + 1] - p[a + 1]
        local dy = p[b + 2] - p[a + 2]
        local dz = p[b + 3] - p[a + 3]
        lens[i - 1] = math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local longest, at = 0, 0
    for i, L in ipairs(lens) do
        if L > longest then longest, at = L, i end
    end

    -- Sorted copy: `lens` is still needed in its own order to report WHERE.
    local sorted = {}
    for i, L in ipairs(lens) do sorted[i] = L end
    local med = median(sorted)
    if med <= 0 then return 0, longest, at end
    return longest / med, longest, at
end

---Remove, in place, every route whose ends are not at its named stops, or
---which contains a segment grossly out of scale with the rest of itself.
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
            else
                local ratio, longest, at = M.segmentOutlier(p)
                if ratio > M.MAX_SEGMENT_RATIO then
                    why = string.format(
                        'stray point: segment %d of %d jumps %.0f, %.0fx the'
                        .. ' median for this route',
                        at, math.floor(#p / 3) - 1, longest, ratio)
                end
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
