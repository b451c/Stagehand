-- modules/agent/ui.lua - the Agent tab: who is connected and what it did last, the three switches the user owns
-- (agent access, changes, renders), the install panel (the MCP server and the skill shipped in the package,
-- the ctl folder, the discovery file, a config snippet for Claude Desktop / Claude Code copied to the
-- clipboard) and the last commands. Drawing only; init.lua acts. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local config = require('config')
local ctl = require('lib.ctl')
local js = require('platform.js')
local i18n = require('i18n')

local t = i18n.t

local U = {}

local ImGui, ctx, app, S, M
local sep = package.config:sub(1, 1)

function U.init(app_, S_, M_)
  app, S, M = app_, S_, M_
  ImGui = app.ImGui
end

local function row_text(dl, x, y0, s, colname, max_w, font, rh)
  theme.push_font(ImGui, ctx, font or 'body')
  local _, th = ImGui.CalcTextSize(ctx, 'Ag')
  local cut = widgets.text_at(ctx, dl, x, y0 + (rh - th) / 2, s, theme.col(colname), max_w)
  theme.pop_font(ImGui, ctx)
  return cut
end

local function next_line(x, y)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, 0, 0)
end

-- paths of what the package ships ----------------------------------------------------------------------------------------

function U.server_path()
  return app.script_dir .. sep .. 'agent' .. sep .. 'stagehand_mcp.py'
end

function U.skill_path()
  return app.script_dir .. sep .. 'agent' .. sep .. 'skills' .. sep .. 'stagehand'
end

local function python()
  return js.is_win and 'python' or 'python3'
end

-- the mcpServers snippet (Claude Desktop, Cursor, Claude Code's .mcp.json all read this shape)
function U.mcp_snippet()
  local path = U.server_path():gsub('\\', '\\\\')
  return string.format('{\n  "mcpServers": {\n    "stagehand": {\n      "command": "%s",\n      "args": ["%s"]\n    }\n  }\n}', python(), path)
end

function U.claude_code_line()
  local path = U.server_path()
  if path:find('%s') then path = '"' .. path .. '"' end
  return string.format('claude mcp add stagehand -- %s %s', python(), path)
end

-- header ------------------------------------------------------------------------------------------------------------------

local function draw_header()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local rh = theme.row_h
  theme.push_font(ImGui, ctx, 'title')
  local title = t('agent.title')
  local tw = ImGui.CalcTextSize(ctx, title)
  local _, th = ImGui.CalcTextSize(ctx, 'Ag')
  ImGui.DrawList_AddText(dl, x0, y0 + (rh - th) / 2, theme.col('text'), title)
  theme.pop_font(ImGui, ctx)
  local x = x0 + tw + theme.space[3]
  local badge = S.agent and t('agent.badge_connected') or t('agent.badge_idle')
  local col = S.agent and 'ok' or 'dim'
  theme.push_font(ImGui, ctx, 'small')
  local bw, bh = ImGui.CalcTextSize(ctx, badge)
  local pad = theme.space[2]
  local by = y0 + (rh - bh - pad) / 2
  ImGui.DrawList_AddRectFilled(dl, x, by, x + bw + pad * 2, by + bh + pad, theme.col(col, 0.18), theme.radius.s)
  ImGui.DrawList_AddText(dl, x + pad, by + pad / 2, theme.col(col), badge)
  theme.pop_font(ImGui, ctx)
  local status
  if S.agent then
    status = string.format(t('agent.status.connected'), S.agent, reaper.time_precise() - (S.agent_t or 0), S.n_cmds, S.n_refused)
  else
    status = t('agent.status.idle')
  end
  row_text(dl, x + bw + pad * 2 + theme.space[3], y0, status, 'muted', w - (x + bw + pad * 2 + theme.space[3] - x0), 'small', rh)
  next_line(x0, y0 + rh)
end

-- the switches --------------------------------------------------------------------------------------------------------------

local SWITCHES = {
  { key = 'agent.enable', label = 'agent.sw.enable', tip = 'agent.sw.enable.tip' },
  { key = 'agent.allow_changes', label = 'agent.sw.changes', tip = 'agent.sw.changes.tip' },
  { key = 'agent.allow_render', label = 'agent.sw.render', tip = 'agent.sw.render.tip' },
}

local function draw_switches()
  for i, sw in ipairs(SWITCHES) do
    if i > 1 then ImGui.SameLine(ctx, 0, theme.space[3]) end
    local on = config.get(sw.key) ~= false
    local changed, v = ImGui.Checkbox(ctx, t(sw.label) .. '##' .. sw.key, on)
    if changed then
      app.note('agent switch ' .. sw.key)
      config.set(sw.key, v, 'global')
      M.say(string.format(t('agent.msg.switch'), t(sw.label), v and t('agent.on') or t('agent.off')))
    end
    widgets.tooltip(ctx, t(sw.tip))
  end
end

-- install panel ------------------------------------------------------------------------------------------------------------------

local function draw_install()
  local rh = theme.row_h_compact
  local rows = {
    { t('agent.in.server'), U.server_path() },
    { t('agent.in.skill'), U.skill_path() },
    { t('agent.in.ctl'), ctl.dir() or t('agent.in.no_project') },
    { t('agent.in.discovery'), S.discovery_path or (S.discovery_err and (t('agent.in.discovery_failed') .. ' ' .. S.discovery_err)) or (config.get('agent.discovery') == false and t('agent.in.discovery_off') or '-') },
  }
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local h = rh * #rows + theme.space[2] * 2 + theme.control_h + theme.space[2]
  local visible = ImGui.BeginChild(ctx, 'install', 0, h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local y = y0 + theme.space[1]
    theme.push_font(ImGui, ctx, 'small')
    local lw = 0
    for _, r in ipairs(rows) do lw = math.max(lw, (ImGui.CalcTextSize(ctx, r[1]))) end
    theme.pop_font(ImGui, ctx)
    lw = lw + theme.space[2]
    for _, r in ipairs(rows) do
      row_text(dl, x0 + 6, y, r[1], 'dim', lw, 'small', rh)
      row_text(dl, x0 + 6 + lw, y, r[2], 'muted', w - lw - 12, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, x0, y)
      ImGui.Dummy(ctx, w, rh)
      widgets.tooltip(ctx, r[2])
      y = y + rh
    end
    next_line(x0 + 6, y + theme.space[1])
    if widgets.button(ctx, 'copy_snippet', t('agent.btn.copy_snippet')) then
      ImGui.SetClipboardText(ctx, U.mcp_snippet())
      M.say(t('agent.msg.copied_snippet'))
    end
    widgets.tooltip(ctx, U.mcp_snippet())
    ImGui.SameLine(ctx, 0, theme.space[2])
    if widgets.button(ctx, 'copy_cc', t('agent.btn.copy_claude_code')) then
      ImGui.SetClipboardText(ctx, U.claude_code_line())
      M.say(t('agent.msg.copied_line'))
    end
    widgets.tooltip(ctx, U.claude_code_line())
    ImGui.SameLine(ctx, 0, theme.space[2])
    if widgets.button(ctx, 'copy_skill', t('agent.btn.copy_skill')) then
      ImGui.SetClipboardText(ctx, U.skill_path())
      M.say(t('agent.msg.copied_skill'))
    end
    widgets.tooltip(ctx, t('agent.btn.copy_skill.tip'))
  end
  ImGui.EndChild(ctx)
end

-- the last commands ------------------------------------------------------------------------------------------------------------------

local function draw_commands()
  local footer_h = theme.space[2] + theme.type.small + theme.space[2]
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'commands', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local rh = theme.row_h_compact
    local y = y0 + theme.space[1]
    row_text(dl, x0 + 6, y, t('agent.cmd.title'), 'dim', w - 12, 'small', rh)
    y = y + rh
    if #S.last == 0 then
      row_text(dl, x0 + 6, y, t('agent.cmd.none'), 'muted', w - 12, 'small', rh)
      y = y + rh
    end
    local now = reaper.time_precise()
    for i = #S.last, 1, -1 do
      local c = S.last[i]
      local age = string.format('%4.0f s', now - c.t)
      row_text(dl, x0 + 6, y, age, 'dim', 48, 'small', rh)
      row_text(dl, x0 + 58, y, c.token or '-', c.ok and 'ok' or 'danger', 70, 'small', rh)
      row_text(dl, x0 + 132, y, c.line or '', 'text', w - 138, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, x0, y)
      ImGui.Dummy(ctx, w, rh)
      widgets.tooltip(ctx, c.line or '')
      y = y + rh
    end
    local cs = ctl.status()
    if #cs.ring > 0 then
      y = y + theme.space[1]
      row_text(dl, x0 + 6, y, t('agent.cmd.last_token') .. ' ' .. cs.ring[#cs.ring], 'muted', w - 12, 'small', rh)
      y = y + rh
    end
    next_line(x0, y)
  end
  ImGui.EndChild(ctx)
end

local function draw_footer()
  local msg = S.msg_frames > 0 and S.msg or nil
  widgets.status(ctx, msg, t('agent.hint'), msg ~= nil)
end

local function handle_keys()
  if not app.focused or ImGui.IsAnyItemActive(ctx) then return end
  if ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | ImGui.Key_D) then app.toggle_dock() end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  draw_header()
  draw_switches()
  ImGui.Spacing(ctx)
  if not S.compact then draw_install() end
  draw_commands()
  draw_footer()
  handle_keys()
end

return U
