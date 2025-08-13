-- -*- coding: utf-8 -*-
-- Multi-worker safe encrypt_seed module for VeryNginx / OpenResty

local VeryNginxConfig = require "VeryNginxConfig"
local dkjson          = require "dkjson"

local _M = {}
_M.seed = nil

-- --- helpers ---------------------------------------------------------------

local function get_home_path()
    local ok, p = pcall(VeryNginxConfig.home_path)
    if ok and p and p ~= "" then
        return p
    end
    return "/opt/verynginx"
end

local function get_seed_path()
    -- 与原版本保持路径一致（默认在 .../configs/encrypt_seed.json）
    return get_home_path() .. "/configs/encrypt_seed.json"
end

local function read_file_seed(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    local ok, obj = pcall(dkjson.decode, data)
    if not ok or not obj then
        return nil
    end
    -- 兼容两种字段
    return obj.encrypt_seed or obj.seed
end

local function write_file_seed(path, seed)
    local f, err = io.open(path, "w")
    if not f then
        ngx.log(ngx.ERR, "encrypt_seed: open for write failed: ", err, " path=", path)
        return false
    end
    local ok, data = pcall(dkjson.encode, { encrypt_seed = seed }, { indent = true })
    if not ok then
        data = '{"encrypt_seed":"' .. seed .. '"}'
    end
    f:write(data)
    f:close()
    return true
end

local function generate_seed()
    -- 生成足够分散的原始熵，再 md5 成固定长度十六进制
    local wid = (ngx.worker and ngx.worker.id and ngx.worker.id()) or ""
    local raw = table.concat({
        tostring(ngx.now()),
        tostring(ngx.time()),
        tostring(wid),
        tostring(math.random()),
        tostring(package.path or ""),
        tostring({})
    }, ":")
    return ngx.md5(raw)
end

-- --- public API ------------------------------------------------------------

function _M.get_seed()
    -- 1) 进程内缓存（避免频繁 shdict/IO）
    if _M.seed and _M.seed ~= "" then
        return _M.seed
    end

    local dict = ngx.shared.verynginx_kv
    local seed_key = "encrypt_seed"

    -- 2) 共享内存（跨 worker）
    if dict then
        local s = dict:get(seed_key)
        if s and s ~= "" then
            _M.seed = s
            return _M.seed
        end
    end

    -- 3) 进入“生成/落盘/写共享内存”的临界区（加锁防并发）
    local have_lock_lib, locklib = pcall(require, "resty.lock")
    if have_lock_lib and dict then
        local lock, err = locklib:new("verynginx_kv", { timeout = 5, exptime = 0 })
        if not lock then
            ngx.log(ngx.WARN, "encrypt_seed: resty.lock new() failed: ", err)
        else
            local elapsed, lerr = lock:lock("encrypt_seed_lock")
            if not elapsed then
                ngx.log(ngx.WARN, "encrypt_seed: lock failed: ", lerr)
            else
                -- 双检：拿到锁后再读一次共享内存
                local s2 = dict:get(seed_key)
                if s2 and s2 ~= "" then
                    _M.seed = s2
                else
                    -- 优先从文件恢复（如果存在）
                    local path = get_seed_path()
                    local fseed = read_file_seed(path)
                    if fseed and fseed ~= "" then
                        _M.seed = fseed
                    else
                        -- 真正生成新 seed
                        _M.seed = generate_seed()
                        -- 尽力写文件（目录不存在或无权限会失败，但不影响返回）
                        write_file_seed(path, _M.seed)
                    end
                    -- 写共享内存，持久到 reload 前
                    dict:set(seed_key, _M.seed, 0)
                end
                -- 解锁
                local ok_unlock, uerr = lock:unlock()
                if not ok_unlock then
                    ngx.log(ngx.WARN, "encrypt_seed: unlock failed: ", uerr)
                end
            end
        end
    end

    -- 4) 无锁/无共享字典的回退路径（仍保证返回非空且进程内一致）
    if not _M.seed or _M.seed == "" then
        local path = get_seed_path()
        _M.seed = read_file_seed(path) or generate_seed()
        -- 尽力写文件/共享内存（如果存在）
        write_file_seed(path, _M.seed)
        if dict then
            dict:add(seed_key, _M.seed, 0)  -- 若已存在不会覆盖
        end
    end

    return _M.seed
end

function _M.generate()  -- 保留空实现，兼容旧接口
end

return _M