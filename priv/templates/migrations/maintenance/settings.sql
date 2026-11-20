<%= case fragment do %>
<% :top_level -> %>
-- rule:rls-prune-catalog-count
SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD'
-- rule:routine-lock-timeout-catalog
-- rule:routine-lock-timeout-scope
SET row_security = on SET lock_timeout = '5s'
<% :inside -> %>
-- rule:routine-inside-search-path
SET search_path = pg_catalog, pg_temp SET DateStyle = 'ISO, YMD' SET row_security = on
<% :definer -> %>
-- rule:routine-step-definer
DEFINER
<% :invoker -> %>
-- rule:routine-helper-invoker
INVOKER
<% end %>
