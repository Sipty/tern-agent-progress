--!strict
-- Agent Progress, window half: marks every tab that holds an omp agent.
--   working        spinning ring
--   waiting_input  gold quest "!"
--   finished       gold turn-in "?", until the tab is visited
-- plus a thin bar and "done/total" from the agent's latest todo list.
--
-- `tern.chrome.tab_title` only reaches the horizontal tab bar, and the tab
-- rows carry no per-tab state classes, so the marks are painted by a
-- generated stylesheet that targets each row by its position in the current
-- session. That works for vertical and horizontal tabs alike.

-- How often agent states are sampled.
local POLL_MS = 1000
-- Poll interval while no agent exists in this window.
local IDLE_POLL_MS = 5000
-- Minimum gap between transcript reads of one working agent.
local TODO_REFRESH_MS = 4000
-- Messages scanned for a todo call on an agent's first read, and later.
-- Reads are synchronous and a timer tick has a 50 ms budget, so each tick
-- reads at most one transcript.
local TODO_SCAN_FIRST = 150
local TODO_SCAN = 40

-- Row selectors; `%d` is the tab's one-based position in the current session.
local VERTICAL_ROW = ".nav-group.g-sp-cur .nav-items > div > button.nav-row:nth-of-type(%d)"
local HORIZONTAL_ROW = "#tabbar .tb-tabs > button.tt:nth-of-type(%d)"

-- Icons as data: URLs, read once at load, so the generated sheet is
-- self-contained and renders the same wherever it is installed.
local function icon_url(name: string): string
	return "data:image/svg+xml;base64," .. tern.base64.encode(tern.fs.read("icons/" .. name .. ".svg"))
end
local ICONS = {
	waiting_input = icon_url("quest"),
	working = icon_url("working"),
	done = icon_url("turnin"),
}

type Todo = { done: number, total: number }
type Agent = {
	state: string,
	todo: Todo?,
	read_at: number, -- tern.now() of the last transcript read, -inf before the first
	dirty: boolean, -- state changed since the last read; the final todo update may be unread
	unseen: boolean, -- finished a turn while its tab was not active
}

-- Agents by pane id, carried between polls to detect transitions.
local agents: { [number]: Agent } = {}
-- The stylesheet last installed, so unchanged polls cost no restyle.
local installed_css = ""

-- Latest "done/total" a todo tool call reported, newest message first.
local function latest_todo(cx: WindowCx, pane: number, last: number): Todo?
	local ok, messages = pcall(function()
		return cx.agents:transcript(pane, { last = last })
	end)
	if not ok then
		return nil
	end
	for i = #messages, 1, -1 do
		local tools = messages[i].tools
		for j = #tools, 1, -1 do
			local tool = tools[j]
			if tool.name == "todo" and type(tool.target) == "string" then
				local done, total = string.match(tool.target, "^(%d+)/(%d+)$")
				if done and total then
					return { done = tonumber(done) :: number, total = tonumber(total) :: number }
				end
			end
		end
	end
	return nil
end

-- Folds the agents of one tab into the mark it shows: input beats work beats
-- an unseen finish. The mark is nil when the tab has nothing to show.
local function tab_mark(panes: { number }): (string?, Todo?)
	local rank = { waiting_input = 3, working = 2, done = 1 }
	local best, best_rank, todo = nil, 0, nil
	for _, pane in panes do
		local agent = agents[pane]
		local kind = if agent.state == "waiting_input" or agent.state == "working"
			then agent.state
			elseif agent.unseen then "done"
			else nil
		local r = if kind then rank[kind] else 0
		if r > best_rank then
			best, best_rank = kind, r
		end
		todo = todo or agent.todo
	end
	return best, todo
end

local function row_rules(position: number, kind: string?, todo: Todo?, active_state: string?): string
	local v = string.format(VERTICAL_ROW, position)
	local h = string.format(HORIZONTAL_ROW, position)
	local out = {}
	if kind then
		local spin = if kind == "working" then " animation: agentprogress-spin 1.1s linear infinite;" else ""
		table.insert(out, string.format(
			"%s .lbl::before, %s .nm::before { content: \"\"; display: inline-block; width: 13px; height: 13px;"
				.. " margin-right: 6px; vertical-align: -2px; background-image: url(\"%s\");"
				.. " background-size: contain; background-repeat: no-repeat; background-position: center;%s }",
			v, h, ICONS[kind], spin
		))
	end
	-- A finished list stays visible only while the agent still works or the
	-- user has not seen the result; otherwise old lists would never go away.
	if todo and todo.total > 0 and (todo.done < todo.total or active_state == "working" or kind == "done") then
		local pct = math.floor(todo.done / todo.total * 100 + 0.5)
		table.insert(out, string.format(
			"%s, %s { background-image: linear-gradient(to right, #d98a00, #ffd100 %d%%, rgba(127,127,127,0.22) %d%%);"
				.. " background-repeat: no-repeat; background-position: left bottom; background-size: 100%% 2px; }",
			v, h, pct, pct
		))
		table.insert(out, string.format(
			"%s .lbl::after, %s .nm::after { content: \" %d/%d\"; color: var(--t3); font-size: 11px; margin-left: 4px; }",
			v, h, todo.done, todo.total
		))
	end
	return table.concat(out, "\n")
end

local function refresh(cx: WindowCx)
	local now = tern.now()
	local focused = cx.session:focused()
	local active_tab = if focused then cx.session:tab_of(focused) else nil

	-- Sample states and flag unseen finishes.
	local seen: { [number]: boolean } = {}
	for _, info in cx.agents:list() do
		seen[info.pane] = true
		local agent = agents[info.pane]
		if agent == nil then
			agent = { state = info.state, todo = nil, read_at = -math.huge, dirty = false, unseen = false }
			agents[info.pane] = agent
		end
		if agent.state == "working" and info.state == "idle" and cx.session:tab_of(info.pane) ~= active_tab then
			agent.unseen = true
		end
		if info.state ~= agent.state then
			agent.dirty = true
		end
		agent.state = info.state
	end
	for pane in agents do
		if not seen[pane] then
			agents[pane] = nil
		end
	end

	-- Refresh one todo count per tick: the agent waiting longest among those
	-- never read, changed state, or working with a stale count.
	local pick, pick_at = nil, math.huge
	for pane, agent in agents do
		local stale = agent.state == "working" and now - agent.read_at >= TODO_REFRESH_MS
		if (agent.read_at == -math.huge or agent.dirty or stale) and agent.read_at < pick_at then
			pick, pick_at = pane, agent.read_at
		end
	end
	if pick then
		local agent = agents[pick]
		local last = if agent.read_at == -math.huge then TODO_SCAN_FIRST else TODO_SCAN
		agent.todo = latest_todo(cx, pick, last) or agent.todo
		agent.read_at, agent.dirty = now, false
	end

	-- Group agent panes by tab; visiting a tab clears its unseen finishes.
	local by_tab: { [number]: { number } } = {}
	for pane, agent in agents do
		local tab = cx.session:tab_of(pane)
		if tab then
			if tab == active_tab then
				agent.unseen = false
			end
			by_tab[tab] = by_tab[tab] or {}
			table.insert(by_tab[tab], pane)
		end
	end

	-- Only the current session's rows are addressable by position.
	local session: number? = nil
	for _, tab in cx.session:tabs() do
		if tab.id == active_tab then
			session = tab.session
		end
	end
	local rules = {}
	for _, tab in cx.session:tabs() do
		local panes = by_tab[tab.id]
		if panes and tab.session == session then
			local kind, todo = tab_mark(panes)
			local active_state = nil
			for _, pane in panes do
				if agents[pane].state == "working" then
					active_state = "working"
				end
			end
			local rule = row_rules(tab.position, kind, todo, active_state)
			if rule ~= "" then
				table.insert(rules, rule)
			end
		end
	end
	local css = table.concat(rules, "\n")
	if css ~= installed_css then
		tern.css("tabs", css)
		installed_css = css
	end
end

-- The last error raised, so a persistent failure is reported once, not every tick.
local last_error: string? = nil

local function poll(cx: WindowCx?)
	-- Re-arm before raising: one bad tick must not end the loop.
	local ok, err = true, nil
	if cx then
		ok, err = pcall(refresh, cx)
	end
	tern.timer(if next(agents) then POLL_MS else IDLE_POLL_MS, poll)
	if not ok and tostring(err) ~= last_error then
		last_error = tostring(err)
		error(err, 0)
	end
end

-- A reload need not emit window_start, so start polling at load as well.
tern.timer(0, poll)
