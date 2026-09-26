local db = require("lapis.db")
local json_params = require("lapis.application").json_params
local cjson = require("cjson")
local models = require('models')
local capture_bad_request_params_validate = require("lib.routes").capture_bad_request_params_validate
local types = require("lapis.validate.types")
local tableshape = require("tableshape").types
local get_optional_query_parameters = require("lib.routes").get_optional_query_parameters
local get_db_query_params_from_request_params = require("lib.routes").get_db_query_params_from_request_params
local get_db_where_clause_from_request_params = require("lib.routes").get_db_where_clause_from_request_params
local create_search_map_clause = require("lib.routes").create_search_map_clause
local export_response = require("lib.export_response")
local resolve_relative_date = require("lib.routes").resolve_relative_date
local created_after_param = require("lib.routes").created_after_param
local created_before_param = require("lib.routes").created_before_param
local escaped_like_clause = require("lib.routes").escaped_like_clause
local compose = require("lib.routes").compose
local with_error_handling = require("lib.routes").with_error_handling
local pick_params = require("lib.routes").pick_params
local with_transaction = require("lib.routes").with_transaction

local base_path = "/api/notification_channels"
local policies_base_path = "/api/notification_policies"
local deliveries_base_path = "/api/alert_deliveries"

local DELIVERIES_EXPORT_COLUMNS = {
  "alert_id", "channel_id", "status", "worker_id", "taken_at", "notified_at",
  "error_message", "updated_at", "channel_name", "channel_type",
  "alert_severity", "rule_name",
}

local Plugin = {
  name = 'notifications_channels',
  dependencies = {'security'},
}

function Plugin.setup(app, deps)
    local security = deps.security
    local auth, rbac, perms = security.auth, security.rbac, security.perms
    local require_auth = auth:with({require = true})

    -- Endpoint: List all notification channels
    app:get(base_path, compose(require_auth, rbac:with(perms.CHANNELS_READ))(get_optional_query_parameters({
        {"from", tableshape.number, tonumber},
        {"size", tableshape.number, tonumber},
        {"name",tableshape.string, nil},
        {"search",tableshape.string, nil},
        {"sort",tableshape.string, nil},
        {"id", tableshape.number, tonumber},
    })(function(self)

        local where_params = {
                "name",
                "id",
                {
                    key="search",
                    map_clause=create_search_map_clause({"name"})
                },
                created_after_param(),
                created_before_param(),
            }
        local db_query = get_db_query_params_from_request_params(
            self,
            where_params
        )
        local where_clause = get_db_where_clause_from_request_params(self, where_params)

        -- local db_query = get_db_query_params_from_request_params(self, {"enabled", "name", "id"})
        -- local where_clause = get_db_where_clause_from_request_params(self, {"name", "id"})

        local result = models.NotificationChannels:select(db_query)
        local total_items = models.NotificationChannels:count(where_clause)
        return { json = {items = result or {}, total_items=total_items} }
    end)))

    -- Endpoint: Get a notification channel by id
    app:get(base_path .. "/:id", compose(require_auth, rbac:with(perms.CHANNELS_READ))(function(self)
        local id = self.params.id
        local item = models.NotificationChannels:find({id=id})
        if not item then
            return { status=404, json = { message = "Notification channel was not found", id = id }}
        end
        return { json = {item = item} }
    end))

    -- Endpoint: Create a notification channel
    app:post(base_path, compose(require_auth, rbac:with(perms.CHANNELS_CREATE))(capture_bad_request_params_validate({
        {"type", types.valid_text},
        {"name", types.valid_text}
    })(function(self)
        -- TODO: validate types and options
        local data = pick_params(self, {"id", "type", "name"})
        data.options = self.params.options

        if not data.options then
            return { status = 400, json = { success = false, message = "Options are not defined for the notification channel." } }
        end

        local ok, result = pcall(function()
            return with_transaction(function() return models.NotificationChannels:create(data) end)
        end)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to add notification channel." } }
        end
    
        return { status = 200, json = { success = true, message = "Notification channel added successfully.", data=result } }
    end)))

    -- Endpoint: Update a notification channel
    app:put(base_path .. "/:id", compose(require_auth, rbac:with(perms.CHANNELS_UPDATE))(capture_bad_request_params_validate({
        {"id", types.db_id},
        {"type", types.valid_text},
        {"name", types.valid_text}
    })(function(self)
        -- TODO: validate types and options
        local data = pick_params(self, {"id", "type", "name"})
        data.options = self.params.options

        if not data.options then
            return { status = 400, json = { success = false, message = "Options are not defined for the notification channel." } }
        end

        local ok, result = pcall(function()
            return with_transaction(function() return models.NotificationChannels:update(data, data.id) end)
        end)

        if not ok then
            return { status = 500, json = { success = false, message = result or "Unable to update notification channel." } }
        end
    
        return { status = 200, json = { success = true, message = "Notification channel updated successfully.", data=result } }
    end)))

    app:delete(base_path .. "/:id", compose(require_auth, rbac:with(perms.CHANNELS_DELETE))(function(self)
        local id = self.params.id

        if not id then
            return { status = 400, json = { error = "Missing notification channel id." } }
        end

        local item = models.NotificationChannels:find({id=id})
        if not item then
            return { status=404, json = { message = "Notification channel was not found", id = id }}
        end

        local opr, err = item:delete()

        if not opr then
            return { status = 500, json = { error = err or "Unable to remove notification channel." } }
        end

        return { json = { success = true, message = "Notification channel removed successfully.", data = err } }
    end))

    app:get(base_path .. "/export", compose(require_auth, rbac:with(perms.CHANNELS_READ))(function(self)
        local items = models.NotificationChannels:select()
        local filename = "notification_channels_export_" .. os.date("%Y-%m-%d") .. ".json"
        return {
            status = 200,
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
            },
            layout = false,
            json = { description = "Notification channels configuration", items = items },
        }
    end))

    app:post(base_path .. "/import", compose(require_auth, rbac:with(perms.CHANNELS_CREATE))(function(self)
        local file = self.params.file
        if not file then
            return { status = 400, json = { message = "File is missing." } }
        end

        local ok_decode, decoded = pcall(cjson.decode, file.content)
        if not ok_decode then
            return { status = 500, json = { ok = false, error = "File content could not be decoded" } }
        end

        local created, failed = {}, 0
        for _, row in ipairs(decoded.items or {}) do
            if not row.options then
                failed = failed + 1
            else
                local ok_create, new_item = pcall(function()
                    return models.NotificationChannels:create({ name = row.name, type = row.type, options = row.options })
                end)
                if ok_create then
                    table.insert(created, new_item)
                else
                    failed = failed + 1
                end
            end
        end

        return { json = { ok = true, content = { items = created, failed = failed } } }
    end))

    -- Notification policies: routes alerts to notification_channels, the
    -- same relationship `rules` has to observations - see
    -- services/policies.lua. Matching a policy against an alert happens
    -- worker-side only (shared/watchtower_worker_core/
    -- notification_policy_matcher.lua); the server just stores policies and
    -- previews a draft condition (POST .../test, notification_policy_engine.
    -- test_expression).
    local policy_manager = require("plugins.notification_channels.services.policies").new(
      models.NotificationPolicies,
      models.NotificationChannels
    )

    app:get(
      policies_base_path,
      compose(
        require_auth,
        rbac:with(perms.POLICIES_READ),
        with_error_handling("Failed to list notification policies", "Failed to list notification policies")
      )(function(self)
        return { status = 200, json = policy_manager:search(self) }
      end)
    )

    app:get(
      policies_base_path .. "/:id",
      compose(require_auth, rbac:with(perms.POLICIES_READ))(function(self)
        local item = policy_manager:find(self.params.id)
        if not item then
          return { status = 404, json = { message = "Notification policy not found", id = self.params.id } }
        end
        return { status = 200, json = { item = item } }
      end)
    )

    app:post(
      policies_base_path,
      compose(
        require_auth,
        rbac:with(perms.POLICIES_CREATE),
        capture_bad_request_params_validate({
          { "source", types.valid_text },
        }),
        with_error_handling("Failed to create notification policy", "Failed to create notification policy")
      )(function(self)
        local item, err = policy_manager:create(self.params)
        if not item then
          return { status = 400, json = { message = "Invalid notification policy", error = err } }
        end
        return { status = 201, json = { message = "Notification policy created", item = item } }
      end)
    )

    app:put(
      policies_base_path .. "/:id",
      compose(
        require_auth,
        rbac:with(perms.POLICIES_UPDATE),
        capture_bad_request_params_validate({
          { "source", types.valid_text },
        }),
        with_error_handling("Failed to update notification policy", "Failed to update notification policy")
      )(function(self)
        local item, err = policy_manager:update(self.params.id, self.params)
        if not item then
          return { status = 400, json = { message = "Invalid notification policy", error = err } }
        end
        return { status = 200, json = { message = "Notification policy updated", item = item } }
      end)
    )

    app:delete(
      policies_base_path .. "/:id",
      compose(
        require_auth,
        rbac:with(perms.POLICIES_DELETE),
        with_error_handling("Failed to delete notification policy", "Failed to delete notification policy")
      )(function(self)
        policy_manager:delete(self.params.id)
        return { status = 200, json = { message = "Notification policy deleted" } }
      end)
    )

    -- Downloads matching policies (all, or `?ids=1,2,3`) as a single .yaml
    -- file (exactly one match) or a .zip of one .yaml per policy (2+
    -- matches) - see services/policies.lua's M:export. Mirrors
    -- GET /api/rules/export.
    app:get(
      policies_base_path .. "/export",
      compose(
        require_auth,
        rbac:with(perms.POLICIES_READ),
        with_error_handling("Failed to export notification policies", "Failed to export notification policies")
      )(function(self)
        local ids = nil
        if self.params.ids and self.params.ids ~= "" then
          ids = {}
          for id_str in self.params.ids:gmatch("[^,]+") do
            table.insert(ids, tonumber(id_str))
          end
        end

        local content, content_type, filename, no_match_err = policy_manager:export(ids)

        if not content then
          return { status = 404, json = { message = no_match_err or "No notification policies to export" } }
        end

        return {
          status = 200,
          content_type = content_type,
          headers = { ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"' },
          layout = false,
          content,
        }
      end)
    )

    -- Parses+validates an uploaded policy file or zip of policy files
    -- without saving anything - see services/policies.lua's
    -- M:preflight_import. Mirrors POST /api/rules/import/preflight.
    app:post(
      policies_base_path .. "/import/preflight",
      compose(
        require_auth,
        rbac:with(perms.POLICIES_CREATE),
        with_error_handling("Failed to preflight notification policy import", "Failed to process upload")
      )(function(self)
        local file = self.params.file
        if not file then
          return { status = 400, json = { message = "File is missing." } }
        end

        local candidates, derive_err = policy_manager:preflight_import(file.filename, file.content)
        if not candidates then
          return { status = 400, json = { message = derive_err } }
        end

        return { status = 200, json = { items = candidates } }
      end)
    )

    -- Commits a client-resolved decision array from a prior preflight:
    -- `{ items: [{ source, action: "create"|"update", existing_id? }] }`.
    -- Gated on both POLICIES_CREATE and POLICIES_UPDATE since a single
    -- batch can do either. Mirrors POST /api/rules/import.
    app:post(
      policies_base_path .. "/import",
      compose(
        require_auth,
        rbac:with(perms.POLICIES_CREATE),
        rbac:with(perms.POLICIES_UPDATE),
        with_error_handling("Failed to commit notification policy import", "Failed to import notification policies")
      )(json_params(function(self)
        local items = self.params.items
        if type(items) ~= "table" then
          return { status = 400, json = { message = "items must be an array" } }
        end

        local results = policy_manager:commit_import(items)

        return { status = 200, json = { results = results } }
      end))
    )

    -- Tests a single ad-hoc `if:` expression against a sample alert-like
    -- payload, without saving a policy - lets an author preview a draft
    -- condition before committing it via POST/PUT .../notification_policies.
    -- Mirrors POST /api/rules/test-expression.
    app:post(
      policies_base_path .. "/test",
      compose(
        require_auth,
        rbac:with(perms.POLICIES_READ),
        capture_bad_request_params_validate({
          { "if", types.valid_text },
          { "severity", types.empty + types.valid_text },
          { "tags", types.empty + types.array_of(types.valid_text) },
          { "rule_id", types.empty + types.valid_text + types.number },
          { "observable_id", types.empty + types.valid_text + types.number },
        }),
        with_error_handling("Failed to test notification policy", "Failed to test notification policy")
      )(function(self)
        local policy_engine_module = require("plugins.notification_channels.services.notification_policy_engine")
        -- The same alert -> matching-context mapping the worker-side matcher
        -- uses, so a policy previews here exactly as it will match there.
        local matched, err = policy_engine_module.test_expression(
          self.params["if"],
          require("watchtower_worker_core.notification_policy_matcher").build_match_context(self.params)
        )

        if err then
          return { status = 400, json = { message = "Invalid expression", error = err } }
        end

        return { status = 200, json = { matched = matched } }
      end)
    )

    -- Read-only, flat view over the per-(alert, channel) delivery queue/
    -- outcome the notify pipeline produces (see alert_deliveries's own
    -- header comment in config/dataset/init.sql, and
    -- services/delivery_queue.lua below) - alerts.deliveries already
    -- surfaces this nested per-alert, this is the filterable/sortable/
    -- paginated flat equivalent for a dedicated list view. alert_deliveries
    -- has a composite (alert_id, channel_id) primary key, not a single `id`
    -- column, so only resource_manager's :search is used here - its
    -- :find/:update/:delete all hardcode `where id = ?` and would break
    -- against this table; a detail-by-id route isn't needed anyway since
    -- each row's own alert/channel are separately viewable via
    -- GET /api/alerts/:id and /api/notification_channels/:id.
    local delivery_manager = require("lib.resource_manager").new(models.AlertDeliveries, {
      fields_query_params = {
        "channel_id",
        "status",
        {
          key = "notified_after",
          map_clause = function(p)
            return "notified_at >= " .. db.escape_literal(resolve_relative_date(p.value))
          end,
        },
        {
          key = "notified_before",
          map_clause = function(p)
            return "notified_at <= " .. db.escape_literal(resolve_relative_date(p.value))
          end,
        },
      },
      fields_search_params = {
        {
          key = "search",
          map_clause = function(p)
            return string.format(
              "EXISTS (SELECT 1 FROM notification_channels nc WHERE nc.id = alert_deliveries.channel_id AND %s) OR %s",
              escaped_like_clause("nc.name", p.value, "ILIKE"),
              escaped_like_clause("alert_deliveries.worker_id", p.value, "ILIKE")
            )
          end,
        },
      },
      select_fields = "alert_deliveries.*, "
        .. "(select name from notification_channels where notification_channels.id = alert_deliveries.channel_id) as channel_name, "
        .. "(select type from notification_channels where notification_channels.id = alert_deliveries.channel_id) as channel_type, "
        .. "(select severity from alerts where alerts.id = alert_deliveries.alert_id) as alert_severity, "
        .. "(select rules.name from alerts join rules on rules.id = alerts.rule_id where alerts.id = alert_deliveries.alert_id) as rule_name",
    })

    app:get(
      deliveries_base_path,
      compose(
        require_auth,
        rbac:with(perms.DELIVERIES_READ),
        with_error_handling("Failed to list notification deliveries", "Failed to list notification deliveries")
      )(function(self)
        return { status = 200, json = delivery_manager:search(self) }
      end)
    )

    -- Downloads every delivery matching the request's current filters/
    -- search/sort (unpaginated - see alerts' identical export route in
    -- plugins/alerting/plugin.lua for the from/size mechanism) as JSON or
    -- CSV (?format=csv). No :find/:update/:delete involved, so the
    -- composite (alert_id, channel_id) primary key (no `id` column) isn't a
    -- problem here, same as delivery_manager:search above.
    app:get(
      deliveries_base_path .. "/export",
      compose(
        require_auth,
        rbac:with(perms.DELIVERIES_READ),
        with_error_handling("Failed to export notification deliveries", "Failed to export notification deliveries")
      )(function(self)
        local result = delivery_manager:search(self)
        return export_response.respond(self, result.items, DELIVERIES_EXPORT_COLUMNS, "alert_deliveries", "Notification deliveries")
      end)
    )

    -- Sender-side ("deliver" role) claim/report cycle over the
    -- alert_deliveries queue - see services/delivery_queue.lua. Fully
    -- independent of scheduler_tasks/jobs, unlike every other worker-facing
    -- claim/report pair in this codebase - gated on DELIVERIES_UPDATE, a
    -- state transition on existing rows like every other claim/report/reap
    -- pair below.
    local delivery_queue = require("plugins.notification_channels.services.delivery_queue").new(
      models.NotificationChannels
    )

    -- Narrow, validating create for the "evaluator"
    -- role's own client-side matching (interval mode - the standalone
    -- worker's shared/watchtower_worker_core/notification_policy_matcher.lua,
    -- see that module's header comment). This route does no matching of its
    -- own - the caller has already decided which policy matched and which
    -- channel to route to; it only validates both ids exist and upserts via
    -- delivery_queue:enqueue, mirroring POST /api/alerts's identical
    -- narrow-create precedent for the "analyzer" role's own client-side
    -- path. delivery_queue:enqueue is a genuine create-or-update (a new
    -- match, or resetting a previously-errored one for retry), so this
    -- route requires both DELIVERIES_CREATE and DELIVERIES_UPDATE.
    app:post(
      deliveries_base_path,
      compose(
        require_auth,
        rbac:with(perms.DELIVERIES_CREATE),
        rbac:with(perms.DELIVERIES_UPDATE),
        capture_bad_request_params_validate({
          { "alert_id", types.db_id },
          { "channel_id", types.db_id },
        }),
        with_error_handling("Failed to enqueue delivery", "Failed to enqueue delivery")
      )(function(self)
        local alert = models.Alerts:find({ id = self.params.alert_id })
        if not alert then
          return { status = 404, json = { message = "Alert not found", alert_id = self.params.alert_id } }
        end
        local channel = models.NotificationChannels:find({ id = self.params.channel_id })
        if not channel then
          return { status = 404, json = { message = "Notification channel not found", channel_id = self.params.channel_id } }
        end
        return { status = 200, json = { enqueued = delivery_queue:enqueue(self.params.alert_id, self.params.channel_id) } }
      end)
    )

    app:put(
      deliveries_base_path .. "/claim",
      compose(
        require_auth,
        rbac:with(perms.DELIVERIES_UPDATE),
        capture_bad_request_params_validate({
          { "worker_id", types.valid_text },
          { "limit", types.empty + types.number },
        }),
        with_error_handling("Failed to claim deliveries", "Failed to claim deliveries")
      )(function(self)
        return { status = 200, json = { item = delivery_queue:claim_batch(self.params.worker_id, self.params.limit) } }
      end)
    )

    app:put(
      deliveries_base_path .. "/report",
      compose(
        require_auth,
        rbac:with(perms.DELIVERIES_UPDATE),
        capture_bad_request_params_validate({
          { "worker_id", types.valid_text },
          { "channel_results", types.empty + types.table },
        }),
        with_error_handling("Failed to report deliveries", "Failed to report deliveries")
      )(function(self)
        delivery_queue:report(self.params.channel_results, self.params.worker_id)
        return { status = 200, json = { message = "Deliveries reported" } }
      end)
    )

    -- Worker-facing housekeeping tick, the "evaluator" role's counterpart to
    -- plugins/jobs/plugin.lua's own PUT .../reap-stale: resets any
    -- alert_deliveries row stuck in 'triggering' past `timeout_seconds` back
    -- to 'error' - see services/delivery_queue.lua's reap_stale. A state
    -- transition on existing rows, like claim/report above, so it uses
    -- DELIVERIES_UPDATE rather than the generic WORKERS_WRITE.
    app:put(
      deliveries_base_path .. "/reap-stale",
      compose(
        require_auth,
        rbac:with(perms.DELIVERIES_UPDATE),
        capture_bad_request_params_validate({
          { "timeout_seconds", types.empty + types.db_id },
        }),
        with_error_handling("Failed to reap stale alert deliveries", "Failed to reap stale alert deliveries")
      )(function(self)
        local timeout_seconds = tonumber(self.params.timeout_seconds) or 300
        local items = delivery_queue:reap_stale(timeout_seconds)
        return { status = 200, json = { reaped = #items, items = items } }
      end)
    )

    return {
      channel_manager = models.NotificationChannels,
      policy_manager = policy_manager,
      delivery_manager = delivery_manager,
      delivery_queue = delivery_queue,
    }
end

return Plugin