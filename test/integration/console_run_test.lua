local t = require('luatest')
local g = t.group('console_run')
local fiber = require('fiber') -- luacheck: ignore

local fio = require('fio')

local cartridge_helpers = require('cartridge.test-helpers')

local shared = require('test.helper.integration').shared
local utils = require("test.helper.utils")

local datadir = fio.pathjoin(shared.datadir, 'console_run')

g.cluster = cartridge_helpers.Cluster:new({
    server_command = shared.server_command,
    datadir = datadir,
    use_vshard = true,
    replicasets = {
        {
            alias = 'api',
            uuid = cartridge_helpers.uuid('a'),
            roles = { 'vshard-router' },
            servers = { { instance_uuid = cartridge_helpers.uuid('a', 1) } },
        },
        {
            alias = 'storage-1',
            uuid = cartridge_helpers.uuid('b'),
            roles = { 'vshard-storage' },
            servers = {
                { instance_uuid = cartridge_helpers.uuid('b', 1), },
                { instance_uuid = cartridge_helpers.uuid('b', 2), },
            },
        },
        {
            alias = 'storage-2',
            uuid = cartridge_helpers.uuid('c'),
            roles = { 'vshard-storage' },
            servers = {
                { instance_uuid = cartridge_helpers.uuid('c', 1), },
                { instance_uuid = cartridge_helpers.uuid('c', 2), },
            },
        },
    },
})

g.before_all(function() g.cluster:start() end)
g.after_all(function() g.cluster:stop() end)

local cases = {
    with_config_loader = function()
        for _, server in pairs(g.cluster.servers) do
            server.net_box:eval([[
                require('migrator').set_loader(
                    require('migrator.config-loader').new()
                )
            ]])
        end

        local files = { "01_first.lua", "02_second.lua", "03_sharded.lua" }
        for _, v in ipairs(files) do
            local file = fio.open('test/integration/migrations/' .. v)
            local content = file:read()
            utils.set_sections(g, { { filename = "migrations/source/" .. v, content = content } })
            file:close()
        end
    end,
    with_directory_loader = function()
        for _, server in pairs(g.cluster.servers) do
            server.net_box:eval([[
                require('migrator').set_loader(
                    require('migrator.directory-loader').new('test/integration/migrations')
                )
            ]])
        end
    end
}

for k, configure_func in pairs(cases) do
    g['test_basic_' .. k] = function()
        configure_func()
        utils.cleanup(g)

        local main = g.cluster.main_server
        for _, server in pairs(g.cluster.servers) do
            t.assert(server.net_box:eval('return box.space.first == nil'), server.alias)
        end
        local result = g.cluster.servers[1].net_box:eval('return require("migrator").up()')
        for _, server in pairs(g.cluster.servers) do
            -- spaces may be created with a slight delay on replicas
            g.cluster:retrying({ timeout = 1 }, function()
                t.assert_not(server.net_box:eval('return box.space.first == nil'), server.alias)
            end)
        end

        local expected_applied = { "01_first.lua", "02_second.lua", "03_sharded.lua" }
        t.assert_equals(result, expected_applied)

        local config = main:download_config()
        t.assert_covers(config, {
            migrations = { applied = expected_applied }
        })
        t.assert_covers(config, {
            schema = {
                spaces = {
                    first = {
                        engine = "memtx",
                        format = {
                            { is_nullable = false, name = "key", type = "string" },
                            { is_nullable = true, name = "value", type = "string" },
                        },
                        indexes = {
                            {
                                name = "primary",
                                parts = { { is_nullable = false, path = "key", type = "string" } },
                                type = "TREE",
                                unique = true,
                            },
                            {
                                name = "value",
                                parts = { { is_nullable = true, path = "value", type = "string" } },
                                type = "TREE",
                                unique = false,
                            },
                        },
                        is_local = false,
                        temporary = false,
                    },
                    sharded = {
                        engine = "memtx",
                        format = {
                            { is_nullable = false, name = "key", type = "string" },
                            { is_nullable = false, name = "bucket_id", type = "unsigned" },
                            { is_nullable = true, name = "value", type = "any" },
                        },
                        indexes = {
                            {
                                name = "primary",
                                parts = { { is_nullable = false, path = "key", type = "string" } },
                                type = "TREE",
                                unique = true,
                            },
                            {
                                name = "bucket_id",
                                parts = { { is_nullable = false, path = "bucket_id", type = "unsigned" } },
                                type = "TREE",
                                unique = false,
                            },
                        },
                        is_local = false,
                        sharding_key = { "bucket_id" },
                        temporary = false,
                    },

                },
            },
        })

        result = g.cluster.servers[1].net_box:eval('return require("migrator").up()')
        t.assert_equals(result, {})
    end
end