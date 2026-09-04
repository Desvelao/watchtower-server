local cjson_safe = require("cjson.safe")

local function sleep(seconds)
  if ngx and ngx.sleep then
    ngx.sleep(seconds)
  else
    os.execute(string.format("sleep %s", tonumber(seconds) or 10))
  end
end

-- +/-20% jitter so multiple workers polling on the same fixed interval
-- don't all hit the server in lockstep.
local function jittered(seconds)
  return seconds * (0.8 + math.random() * 0.4)
end

-- Best-effort periodic heartbeat, piggybacked on the input generator's own
-- tick rather than a dedicated timer/thread (the standalone worker has no
-- such primitive). Gated by wall-clock elapsed time against
-- `ctx.config.heartbeat_interval`, since luastash calls input generators on
-- every tick with no pacing of its own - without this gate a heartbeat
-- would fire on every poll, spamming the server. Only used by the
-- standalone worker's input_http (see worker_pipeline.lua) - the embedded
-- worker heartbeats separately via ngx.timer.every (it has that primitive
-- available and its own registration-before-first-report requirement, see
-- server/workers/scrape_pending_worker.lua).
--
-- `jobs.monitor_id` has an FK to `monitors` - a job report for a monitor
-- that was never successfully registered would fail at the DB.
-- `ctx._monitor_registered` is only set true once a heartbeat actually
-- succeeds, so a failed heartbeat retries on the very next tick instead of
-- waiting a full interval.
local function maybe_heartbeat(ctx, connection_type, utils)
  if ctx._monitor_registered == nil then
    ctx._monitor_registered = not (
      ctx.notify
      and ctx.notify.heartbeat
      and ctx.config
      and ctx.config.server
    )
  end

  if not (ctx.notify and ctx.notify.heartbeat) then
    return
  end
  if not (ctx.config and ctx.config.server) then
    return
  end
  local interval = ctx.config.heartbeat_interval or 30
  local now = os.time()
  if ctx._last_heartbeat_at and (now - ctx._last_heartbeat_at) < interval then
    return
  end
  local ok, err = ctx.notify:heartbeat({
    connection_type = connection_type,
    version = ctx.config.server.version,
    capabilities = ctx.config.capabilities,
    item_filter = ctx.config.item_filter,
    uptime_seconds = os.time() - (ctx.notify.started_at or now),
    config = ctx.config.reportable_config_json,
  })
  if ok then
    ctx._last_heartbeat_at = now
    ctx._monitor_registered = true
  else
    utils.logger.warn(
      "maybe_heartbeat: heartbeat failed, will retry next tick: "
        .. tostring(err)
    )
  end
end

local function input_http(options, ctx, utils)
  local http_provider = ctx.http_provider.new(ctx.config.server)
  local poll_interval_seconds = options and options.poll_interval_seconds

  return function()
    maybe_heartbeat(ctx, "http", utils)
    if not ctx._monitor_registered then
      sleep(poll_interval_seconds or 1)
      return true, nil
    end
    local item = http_provider:next()
    if item then
      return true, item
    end
    if poll_interval_seconds then
      sleep(jittered(poll_interval_seconds))
    end
    return true, nil
  end
end

-- Embedded-only: fetches the next item due for a scrape via
-- `ctx.get_pending_item()` (direct in-process DB access, wired by
-- server/workers/scrape_pending_worker.lua - no HTTP round trip needed
-- when the worker runs inside the server process). `options.size` is
-- accepted for parity with pibuzz's input_db_poll shape but unused here -
-- get_pending_item always returns at most one item.
local function input_db_poll(options, ctx, utils)
  return function()
    local ok, item_or_err = pcall(ctx.get_pending_item)

    if not ok then
      utils.logger.warn("input_db_poll: query failed: " .. tostring(item_or_err))
      return true, nil
    end

    if not item_or_err then
      return true, nil
    end

    return true, item_or_err
  end
end

local function input_sleep(options, _ctx)
  local seconds = (options and options.seconds) or 10

  return function()
    sleep(jittered(seconds))
    return true, nil
  end
end

local function filter_processing(options, event, ctx, utils)
  local ok, err = ctx.notify:processing(event.data)
  local status
  if ok then
    status = "filtering"
  else
    status = "error"
    utils.logger.error(
      string.format(
        "[id=%s] - [processing=%s] - [reason=%s]",
        tostring(event.data.id),
        tostring(ok),
        tostring(err)
      )
    )
  end
  event:set_metadata("status_processing", status)
  return event
end

-- Halts the filter chain via pipeflow's utils.end_pipeline() - merely
-- `return nil` here is NOT enough to stop it: pipeflow's step loop only
-- breaks early when a step actually calls end_pipeline(); otherwise it
-- keeps running every remaining step with a nil `data`, which crashes the
-- next filter (filter_ack indexes `event.data`). end_pipeline() is the
-- documented, correct halt mechanism (see pipeflow's 4th processor arg).
local function filter_drop(options, event, ctx, utils)
  utils.end_pipeline()
  return nil
end

-- Runs the actual scrape (via ctx.scraper, a WebScraper instance built by
-- shared/scraper_creator.lua) against the item's URL, and stashes the
-- result on the event's data for filter_ack to turn into an observation.
-- WebScraper:run(url) returns a table when a registered site's
-- urls_match matched (even on a fetch/parse failure - the table just
-- won't have the scraped fields set in that case), or nil when no site
-- matched at all - so "success" here means both a site matched AND a
-- price was actually extracted, not merely a non-nil return.
local function filter_scrape(options, event, ctx, utils)
  local item = event.data
  local ok, result = pcall(function()
    return ctx.scraper:run(item.url)
  end)

  -- WebScraper's extracted fields are always strings (raw HTML content,
  -- however a site's `transform` reshaped it) - never Lua numbers. The
  -- server's POST /api/observations validates `price` as
  -- tableshape.number, so it must be coerced here, once, for both workers
  -- (the embedded worker's direct model :create bypasses that validation
  -- and would silently rely on Postgres' own text->numeric cast instead,
  -- which is the same value either way but fragile to depend on).
  local price = ok and result and tonumber(result.price) or nil

  local status
  if price ~= nil then
    event:set("[scrape_result]", {
      price = price,
      discount = result.discount,
      available = result.available,
      url = item.url,
    })
    status = "scraped"
  else
    status = "error"
    local message
    if not ok then
      message = tostring(result)
    elseif not result then
      message = "no registered site matched this item's URL"
    else
      message = "scrape ran but no price was extracted"
    end
    utils.logger.error(
      string.format("[id=%s] - Scrape failed: %s", tostring(item.id), message)
    )
    -- Reported here rather than in filter_ack: worker_pipeline.lua drops
    -- the event on status_scrape == "error", so filter_ack never runs for
    -- a failed scrape.
    local notify_ok, notify_err = ctx.notify:error(item, message)
    if not notify_ok then
      utils.logger.error(
        string.format(
          "[id=%s] - Failed to report scrape error: %s",
          tostring(item.id),
          tostring(notify_err)
        )
      )
    end
  end

  event:set_metadata("status_scrape", status)
  return event
end

local function filter_ack(options, event, ctx, utils)
  local logger = utils.logger
  local item = event.data
  local scrape_result = event:get("[scrape_result]")
  local action = "scraped"
  local message = cjson_safe.encode(scrape_result) or "scraped"

  local ok, err = ctx.notify:complete(item, action, message, scrape_result)
  local status
  if ok then
    status = "ack"
    logger.info(string.format("[id=%s] - [action=%s]", tostring(item.id), action))
  else
    status = "error"
    logger.error(
      string.format(
        "[id=%s] - [action=%s] - [reason=%s]",
        tostring(item.id),
        action,
        tostring(err)
      )
    )
  end
  event:set_metadata("status_ack", status)
  return event
end

local function output_console(options, event, _, utils)
  utils.logger.info("Outputting item to console: %s", event:to_json())
  return event
end

return {
  input_http = input_http,
  input_db_poll = input_db_poll,
  input_sleep = input_sleep,
  filter_processing = filter_processing,
  filter_drop = filter_drop,
  filter_scrape = filter_scrape,
  filter_ack = filter_ack,
  output_console = output_console,
}
