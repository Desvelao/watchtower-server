-- The grammar rule_expr.lua's condition language (`if:`) is allowed to
-- reference, for this project's domain. Extends pibuzz's original
-- tags/source vocabulary with the price-observation fields an ingested
-- event carries - rule_expr.lua's comparison evaluator is already generic
-- for any flat field (`context[ast.field]`), so this is purely a
-- vocabulary/config change, not a parser change. See shared/rule_expr.lua.
--
-- A rule's `if` is evaluated against the context built in
-- plugins/events/plugin.lua's on_create hook:
--   { source, tags, item, item_id, price, discount, available, url, payload }
return {
  tags = { has = true },
  source = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  item = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  item_id = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  price = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  discount = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  available = { ["="] = true, ["!="] = true },
  url = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  payload = { ["="] = true, ["!="] = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
  ["payload.*"] = { ["="] = true, ["!="] = true, has = true, [">"] = true, ["<"] = true, [">="] = true, ["<="] = true },
}
