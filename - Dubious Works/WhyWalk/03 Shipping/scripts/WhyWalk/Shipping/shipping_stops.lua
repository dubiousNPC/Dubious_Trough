---@omw-context none
--[[
    shipping_stops.lua -- which route carries a guide's passenger to a destination

    Pure. The global script supplies positions and cell names; this picks the
    route.

    WHY NOT CARAVANS' STOP CENTRES

    Caravans gives every place ONE centre (the median of the route endpoints
    that name it) and matches anything within 15,000 units of it. Docks break
    both halves of that, measured on the 140 Shipmaster files:

      * one name, two quays. Almas Thirr's sea routes (Ebonheart, Andothren,
        Old Ebonheart) leave from (55717, -222057); its river routes leave from
        around (44300, -229000), 13,500 units away. One centre puts one of the
        two groups 11,500 units from "Almas Thirr".
      * two names, one quay. Hlaalu Ferry and Maar-Bani Crossing are 278 units
        apart; Llothanis and Llotharis (one place, spelled two ways) 258.
      * neighbours. Vos and Tel Mora are 5,183 apart; the Vos quay for Tel Mora
        is a separate spot 3,400 from the main one. A 15,000 radius would put
        a Tel Mora passenger on a ship leaving Vos.

    WHAT IT DOES INSTEAD

    Every route is tested directly: its departure end must lie within RADIUS
    of the guide and its arrival end within RADIUS of the destination the
    guide's record gives.

    NAMES ARE BINDING WHERE THEY CAN BE. Immersive Travel's route names are
    cell names -- it pairs a route with a destination by
    `cell.name:lower() == destination` -- so when a place's cell name is one
    of the route names, only routes carrying that name may serve it. Without
    this, position alone put Gals Arethi's Tel Mora passengers on the Sadrith
    Mora -> Vos ship (the Vos quay is within reach of Tel Mora's), and
    Tel Mora's own shipmaster sent people to Sadrith Mora from Vos. A place
    whose cell has no name, or a name no route uses, is matched by position
    alone.

    Among the routes that pass: an authored direction beats a reversed one,
    then the closest.

    RADIUS is 8000: the furthest a vanilla shipmaster stands from the start of
    their own routes is 6,033 (Ano Andaram, Vivec Foreign Quarter) and the
    furthest a vanilla destination point lies from a route end is 5,893
    (Vivec Foreign Quarter again).
]]

local M = {}

M.RADIUS = 8000

local function dist(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return math.sqrt(dx * dx + dy * dy)
end

---First and last point of a flat route.
local function ends(p)
    local n = #p
    return p[1], p[2], p[n - 2], p[n - 1]
end
M.ends = ends

---@class ShippingPlace
---@field x number
---@field y number
---@field name string|nil lower-case cell name, or nil

---The best route from `origin` to `dest`, or nil.
---@param routes table list of { from=, to=, x,y,z,... }
---@param origin ShippingPlace the guide
---@param dest ShippingPlace the destination point from the guide's record
---@param radius number|nil
---@param known table|nil from knownNames, cached by the caller
---@return table|nil route, boolean reversed, table|nil why { dOrigin, dDest, names }
---Every name used by a route, for match() to know which names bind.
function M.knownNames(routes)
    local k = {}
    for _, r in ipairs(routes) do k[r.from] = true; k[r.to] = true end
    return k
end

function M.match(routes, origin, dest, radius, known)
    radius = radius or M.RADIUS
    known = known or M.knownNames(routes)
    local needFrom = origin.name and known[origin.name] and origin.name or nil
    local needTo = dest.name and known[dest.name] and dest.name or nil
    local best, bestRev, bestKey, bestWhy = nil, false, nil, nil
    for _, r in ipairs(routes) do
        if #r >= 6 then
            local sx, sy, ex, ey = ends(r)
            for pass = 1, 2 do
                local rev = pass == 2
                local fx, fy, tx, ty = sx, sy, ex, ey
                local fromName, toName = r.from, r.to
                if rev then fx, fy, tx, ty, fromName, toName = ex, ey, sx, sy, r.to, r.from end
                local dO = dist(fx, fy, origin.x, origin.y)
                local dD = dist(tx, ty, dest.x, dest.y)
                if dO <= radius and dD <= radius
                   and (not needFrom or needFrom == fromName)
                   and (not needTo or needTo == toName) then
                    local names = (needFrom and 1 or 0) + (needTo and 1 or 0)
                    -- Lower is better: authored direction, then distance.
                    local key = (rev and 1e8 or 0) + dO + dD
                    if not bestKey or key < bestKey then
                        best, bestRev, bestKey = r, rev, key
                        bestWhy = { dOrigin = dO, dDest = dD, names = names }
                    end
                end
            end
        end
    end
    return best, bestRev, bestWhy
end

-- A spike is a vertex where the course doubles back between two legs that
-- are each far longer than the route's usual leg: a stray point. Open sea
-- legs are long and straight, so a plain "longest leg over the median" test
-- (Caravans' MAX_SEGMENT_RATIO) condemns good routes here; the reversal is
-- what makes it a spike. tools/import_routes.py drops these at import; this
-- is the same test for anything added at runtime.
M.SPIKE_TURN = math.rad(150)
M.SPIKE_LEG = 5

local function median(t)
    table.sort(t)
    local n = #t
    if n == 0 then return 0 end
    if n % 2 == 1 then return t[(n + 1) / 2] end
    return (t[n / 2] + t[n / 2 + 1]) / 2
end

---Describe the first spike in a flat route, or nil.
function M.spike(p)
    local n = math.floor(#p / 3)
    if n < 4 then return nil end
    local L = {}
    for i = 1, n - 1 do
        local a, b = (i - 1) * 3, i * 3
        L[i] = dist(p[a + 1], p[a + 2], p[b + 1], p[b + 2])
    end
    local sorted = {}
    for i, v in ipairs(L) do sorted[i] = v end
    local med = median(sorted)
    for i = 2, n - 1 do
        local a, b, c = (i - 2) * 3, (i - 1) * 3, i * 3
        local h1 = math.atan2(p[b + 1] - p[a + 1], p[b + 2] - p[a + 2])
        local h2 = math.atan2(p[c + 1] - p[b + 1], p[c + 2] - p[b + 2])
        local d = (h2 - h1 + math.pi) % (2 * math.pi) - math.pi
        if math.abs(d) > M.SPIKE_TURN and L[i - 1] > M.SPIKE_LEG * med
           and L[i] > M.SPIKE_LEG * med then
            return string.format('turns %.0f degrees at point %d', math.deg(math.abs(d)), i)
        end
    end
    return nil
end

return M
