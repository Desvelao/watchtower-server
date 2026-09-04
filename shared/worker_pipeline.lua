local INPUT_SELECTORS = {
	standalone = function(config)
		return {
			{
				type = "input_http",
				options = { poll_interval_seconds = config.poll_interval },
			},
		}
	end,

	embedded = function(config)
		return {
			{ type = "input_db_poll", options = { size = 1 } },
			{ type = "input_sleep", options = { seconds = config.poll_interval } },
		}
	end,
}

return function(config, mode)
	local selector = INPUT_SELECTORS[mode or "standalone"]

	if not selector then
		error(string.format("worker_pipeline: unknown mode '%s'", tostring(mode)))
	end

	return {
		inputs = selector(config),
		filters = {
			{
				type = "filter_processing",
				options = {},
			},
			{
				["if"] = "event.metadata['status_processing'] == 'error'",
				type = "filter_drop",
				options = {},
			},
			{
				type = "filter_scrape",
				options = {},
			},
			{
				["if"] = "event.metadata['status_scrape'] == 'error'",
				type = "filter_drop",
				options = {},
			},
			{
				type = "filter_ack",
				options = {},
			},
		},
		outputs = {
			{
				type = "output_console",
				options = {},
			},
		},
	}
end
