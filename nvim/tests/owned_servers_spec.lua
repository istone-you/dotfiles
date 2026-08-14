local T = dofile(TESTS_DIR .. '/helpers.lua')
local owned = require('config.util.owned_servers')

T.describe('owned_servers', function()
  T.it('finds and stops the provider that is serving the given port', function()
    local orig = owned.providers
    local stopped = {}
    package.loaded['owned_servers_fake_a'] = {
      serving_port = function() return 4000 end,
      close = function(opts)
        table.insert(stopped, { id = 'a', silent = opts and opts.silent })
      end,
    }
    package.loaded['owned_servers_fake_b'] = {
      serving_port = function() return 9000 end,
      close = function()
        table.insert(stopped, { id = 'b' })
      end,
    }
    owned.providers = {
      {
        id = 'a',
        label = 'A',
        module = 'owned_servers_fake_a',
        serving_port = function(mod) return mod.serving_port() end,
        stop = function(mod) mod.close({ silent = true }) end,
      },
      {
        id = 'b',
        label = 'B',
        module = 'owned_servers_fake_b',
        serving_port = function(mod) return mod.serving_port() end,
        stop = function(mod) mod.close({ silent = true }) end,
      },
    }

    local provider = owned.find(4000)
    T.eq(provider.id, 'a')
    T.eq(owned.find(1234), nil)

    local ok, p = owned.stop(4000)
    T.eq(ok, true)
    T.eq(p.id, 'a')
    T.eq(stopped, { { id = 'a', silent = true } })

    T.eq(owned.stop(1234), false)

    owned.providers = orig
    package.loaded['owned_servers_fake_a'] = nil
    package.loaded['owned_servers_fake_b'] = nil
  end)
end)

T.summary()
