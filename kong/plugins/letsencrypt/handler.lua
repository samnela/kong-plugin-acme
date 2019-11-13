local BasePlugin = require("kong.plugins.base_plugin")
local kong_certificate = require("kong.runloop.certificate")

local client = require("kong.plugins.letsencrypt.client")


if kong.configuration.database == "off" then
  error("letsencrypt can't be used in Kong dbless mode currently")
end

local acme_challenge_path = [[^/\.well-known/acme-challenge/(.+)]]

-- cache for dummy cert kong generated (it's a table)
local default_cert_key

local LetsencryptHandler = BasePlugin:extend()

LetsencryptHandler.PRIORITY = 1000
LetsencryptHandler.VERSION = "0.0.1"

function LetsencryptHandler:new()
  LetsencryptHandler.super.new(self, "letsencrypt")
end


function LetsencryptHandler:init_worker()
  LetsencryptHandler.super.init_worker(self, "letsencrypt")
  -- create renewal timer
end


-- access phase is to terminate the http-01 challenge request if necessary
function LetsencryptHandler:access(conf)
  LetsencryptHandler.super.access(self)

  local captures, err =
    ngx.re.match(kong.request.get_path(), acme_challenge_path, "jo")
  if err then
    kong.log(kong.WARN, "error matching acme-challenge uri: ", err)
    return
  end

  if captures then
    local acme_client, err = client.new(conf)

    if err then
      kong.log.err("failed to create acme client:", err)
      return
    end

    acme_client:serve_http_challenge()
    return
  end

  local host = kong.request.get_host()
  -- if we are not serving challenge, do normal proxy pass
  -- but record what cert did we used to serve request
  local cert_and_key, err = kong_certificate.find_certificate(host)
  if err then
    kong.log.err("error find certificate for current request:", err)
    return
  end

  if not default_cert_key then
    -- hack: find_certificate() returns default cert and key if no sni defined
    default_cert_key = kong_certificate.find_certificate()
  end

  -- note we compare the table address, this relies on the fact that Kong doesn't
  -- copy the default cert table around
  if cert_and_key ~= default_cert_key then
    kong.log.debug("skipping because non-default cert is served")
    return
  end

  local protocol = kong.client.get_protocol()
  if protocol ~= 'https' then
    kong.log.debug("skipping because request is protocol: ", protocol)
    return
  end

  -- TODO: do we match the whitelist?
  ngx.timer.at(0, function()
    local acme_client, err = client.new(conf)
    if err then
      kong.log.err("failed to create acme client:", err)
      return
    end
    err = client.update_certificate(acme_client, host, nil, conf.cert_type)
    if err then
      kong.log.err("failed to update certificate: ", err)
    end
  end)

end


return LetsencryptHandler
