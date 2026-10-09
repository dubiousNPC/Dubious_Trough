-- dump_db.lua -- print boats_db as JSON (for check_db_sources.py and the doc generator).
package.path = './?.lua;' .. package.path
local db = require('scripts.WhyWalk.Boats.boats_db')

local function encode(v)
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then return string.format('%.10g', v) end
    if t == 'string' then return string.format('%q', v):gsub('\\\n', '\\n') end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format('%q', k) .. ':' .. encode(v[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

print(encode({ VESSELS = db.VESSELS, PROVENANCE = db.PROVENANCE, MODELS = db.MODELS,
               RECORDS = db.RECORDS, TUNING = db.TUNING }))
