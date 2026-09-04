-- Builds a WebScraper instance with all filters/validators registered and
-- every entry in `sites` (an array of {name, urls_match, fields, urls_test})
-- registered as a scrapeable site - the same registration sequence
-- previously duplicated three times inline in
-- server/plugins/scraper_remote_config_lua/plugin.lua's /test routes, now
-- shared by both the plugin (server-side ad-hoc tests, see that plugin's
-- own use of this module) and the workers (real scheduled scrapes, see
-- worker_processors.lua's filter_scrape).
local M = {}

-- Mirrors the same global the plugin sets before ever calling WebScraper -
-- the underlying htmlparser needs this raised above its small default for
-- real-world pages. A global (not local) because htmlparser reads it as a
-- bare global itself; setting it here means every caller of this module
-- gets the same deep-parse limit without duplicating the assignment.
htmlparser_looplimit = 8000

-- Returns (webscraper, capabilities) - capabilities is the sorted,
-- de-duplicated set of configured site names, self-reported in monitor
-- heartbeats so an operator can see which sites a given worker actually
-- knows how to scrape.
function M.new(sites)
  local WebScraper = require("webscraper").WebScraper
  local WebScraperFilters = require("webscraper.filters.filters")
  local WebScraperValidators = require("webscraper.filters.validators")

  local webscraper = WebScraper:new()
  for k, v in pairs(WebScraperFilters) do
    webscraper.filters:register(k, v)
  end
  for k, v in pairs(WebScraperValidators) do
    webscraper.validators:register(k, v)
  end

  local capabilities = {}
  for _, site in ipairs(sites or {}) do
    webscraper.sites:register(site.name, {
      name = site.name,
      urls_match = site.urls_match,
      fields = site.fields,
    })
    table.insert(capabilities, site.name)
  end
  table.sort(capabilities)

  return webscraper, capabilities
end

return M
