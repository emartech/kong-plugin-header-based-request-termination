local cjson = require "cjson"
local Logger = require "logger"

local kong = kong
local ngx = ngx

local ALL_ACCESS = "*"

local function log_termination(message, query)
    Logger.getInstance(ngx):logWarning({
        msg = message,
        uri = kong.request.get_path(),
        source_identifier = query.source_identifier,
        target_identifier = query.target_identifier
    })
end

local function is_legal_access(source_header_value, target_header_value)
    return not target_header_value or source_header_value == target_header_value
end

local function db_count(access_object)
    local query_result = kong.db.connector:query(string.format(
            "SELECT count(1) FROM integration_access_settings WHERE source_identifier = '%s' AND target_identifier = '%s'",
            access_object.source_identifier,
            access_object.target_identifier))

    return query_result[1]["count"]
end

local function find_access_in_db(source_identifier, target_identifier)
    local all_access_query = {
        source_identifier = source_identifier,
        target_identifier = ALL_ACCESS
    }

    local target_access_query = {
        source_identifier = source_identifier,
        target_identifier = target_identifier
    }

    return db_count(all_access_query) > 0 or db_count(target_access_query) > 0
end

local function find_access(source_identifier, target_identifier)
    local cache_key = kong.db.integration_access_settings:cache_key(source_identifier, target_identifier)
    local has_access = kong.cache:get(cache_key, nil, find_access_in_db, source_identifier, target_identifier)

    return has_access
end

local function set_darklaunch_header(has_access)
    local decision = has_access and "allow" or "block"

    kong.service.request.set_header("x-request-termination-decision", decision)
end

local Access = {}

function Access.execute(conf)
    local source_header_value = kong.request.get_header(conf.source_header)
    local target_header_value = kong.request.get_header(conf.target_header)

    if not source_header_value then
        if conf.log_only then
            log_termination("Request terminated based on missing source header", {
                target_identifier = target_header_value
            })
            return
        end

        return kong.response.exit(conf.status_code, cjson.decode(conf.message))
    end

    if is_legal_access(source_header_value, target_header_value) then
        return
    end

    local has_access = find_access(source_header_value, target_header_value)

    if conf.log_only then
        if conf.darklaunch_mode then
            set_darklaunch_header(has_access)
        end

        if not has_access then
            log_termination("Request terminated based on headers", {
                source_identifier = source_header_value,
                target_identifier = target_header_value
            })
            return
        end
    end

    if not has_access then
        return kong.response.exit(conf.status_code, cjson.decode(conf.message))
    end
end

return Access
