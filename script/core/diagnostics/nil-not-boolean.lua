local files = require('files')
local guide = require('parser.guide')
local vm = require('vm')
local await = require('await')

local typesWithOperation = { 'binary', 'unary' }

local typesWithFilter = {
    'ifblock',
    'elseifblock',
    'while',
    'repeat',
}

local typesUseBoolean = {
    ['ifblock'] = assert,
    ['elseifblock'] = assert,

    ['while'] = assert,
    ['repeat'] = assert,

    ['binary'] = function(s)
        return s.op.type == 'and' or s.op.type == 'or'
    end,
    ['unary'] = function(s)
        return s.op.type == 'not'
    end,
}

local function usedAsBoolean(source)
    local parent = source.parent
    local f = typesUseBoolean[parent.type]
    return f and f(parent)
end

local typesUsedAsBoolean = {
    ['getlocal'] = function(s)
        return s[1]
    end,
    ['getglobal'] = function(s)
        return s[1]
    end,
    ['getfield'] = function(s)
        return '.' .. s.field[1]
    end,
    ['getindex'] = function(s)
        local parent = guide.getKeyName(s.node)
        if not parent and s.node.type == 'call' then
            parent = s.node.node[1] .. '()'
        end
        return ('%s[%s]'):format(parent or '', s.index[1])
    end,
    ['call'] = function(s)
        return s.node[1] .. '()'
    end,
}

local function isBool(obj)
    return (obj.type == 'global' and obj.cate == 'type')
        and (obj.name == 'boolean' or obj.name == 'true' or obj.name == 'false')
end

local function message(node, left, isNot)
    local right = 'nil'

    local before = (isNot and 'not ' or '') .. left .. ' => '

    for _, obj in ipairs(node) do
        if isBool(obj) then
            right = 'true'
            isNot = not isNot
            break
        end
    end

    return before .. left .. (isNot and ' == ' or ' ~= ') .. right
end

---@async
return function(uri, callback)
    local state = files.getState(uri)
    if not state then
        return
    end

    local function check(source, isNot)
        if not source then
            return
        end

        local msg = typesUsedAsBoolean[source.type]
        if not msg then
            return
        end

        await.delay()

        local node = vm.compileNode(source)

        if not node:isTyped() then
            return -- skip unknown
        elseif node:isNullable() then
            if not node:isOptional() then
                return -- skip nil any ..., alow only ?
            end
        else
            return -- skip not nullable
        end

        callback({
            start = source.start,
            finish = source.finish,
            message = message(node, msg(source), isNot),
        })
    end

    guide.eachSourceTypes(state.ast, typesWithFilter, function(source)
        check(source.filter)
    end)

    guide.eachSourceTypes(state.ast, typesWithOperation, function(source)
        if source.op.type == 'not' then
            check(source[1], true)
        elseif source.op.type == 'and' then
            check(source[1])

            -- exclude for conditional operator
            local parent = source.parent
            if parent.type == 'binary' and parent.op.type == 'or' and not usedAsBoolean(parent) then
                return
            end

            check(source[2])
        elseif source.op.type == 'or' then
            check(source[1])

            -- exclude for conditional operator
            if source[1].type == 'binary' and source[1].op.type == 'and' and not usedAsBoolean(source) then
                return
            end

            check(source[2])
        end
    end)
end
