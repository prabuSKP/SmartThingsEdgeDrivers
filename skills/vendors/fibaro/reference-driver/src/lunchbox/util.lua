local net_url = require "net.url"

local util = {}

function util.force_url_table(url)
  if type(url) ~= "table" then url = net_url.parse(url) end

  if not url.port then
    if url.scheme == "http" then
      url.port = 80
    elseif url.scheme == "https" then
      url.port = 443
    end
  end

  return url
end

return util
