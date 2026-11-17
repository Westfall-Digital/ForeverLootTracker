-- ForeverLootTracker — reusable UI controls + Forever-native chrome helpers.
-- Visual language mirrors ForeverCompanion (warm bronze pane, side tabs, inset wells)
-- without a runtime dependency on that addon.
local FLT = ForeverLootTracker
FLT.Widgets = FLT.Widgets or {}
local W = FLT.Widgets

-- Companion-style character-sheet palette.
W.COLORS = {
	pane = { 0.012, 0.004, 0.0 },
	border = { 0.23, 0.15, 0.06 },
	bar = { 0.18, 0.145, 0.118 },
	light = { center = { 0.231, 0.165, 0.110 }, edge = { 0.125, 0.075, 0.047 } },
	dark = { center = { 0.145, 0.090, 0.063 }, edge = { 0.078, 0.047, 0.031 } },
	header = { center = { 0.275, 0.192, 0.125 }, edge = { 0.150, 0.095, 0.055 } },
	gold = { 1.0, 0.82, 0.0 },
	warning = { 1.0, 0.55, 0.12 },
	watch = { 0.05, 0.35, 0.08 },
}

local function TemplateExists(name)
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
		local ok, info = pcall(C_XMLUtil.GetTemplateInfo, name)
		return ok and info ~= nil
	end
	return false
end

local function AtlasExists(name)
	if not name then
		return false
	end
	if C_Texture and C_Texture.GetAtlasInfo then
		local ok, info = pcall(C_Texture.GetAtlasInfo, name)
		return ok and info ~= nil
	end
	return false
end

-- List/header stripe opacity (0 = invisible, 1 = opaque).
-- 0.75 = 25% transparent / 75% opaque.
W.LIST_ALPHA = 0.75

local WHITE8 = "Interface\\Buttons\\WHITE8X8"

-- c1/c2 = {r,g,b[,a]}. Alpha is required for visible transparency.
-- Patched vs Companion's helper: use WHITE8x8 + RGBA gradient (filter), and always
-- fall back to SetColorTexture with alpha (documented Forever API).
function W.Gradient(tex, c1, c2, orient)
	orient = orient or "HORIZONTAL"
	local a1, a2 = c1[4] or 1, c2[4] or 1

	-- SetGradient tints the underlying texture (like SetVertexColor). A solid
	-- SetColorTexture(1,1,1,1) base can ignore gradient alpha on some clients;
	-- WHITE8x8 + RGBA CreateColor is the supported modern path.
	local painted = false
	if CreateColor and tex.SetGradient then
		local okTex = pcall(tex.SetTexture, tex, WHITE8)
		if okTex then
			painted = pcall(tex.SetGradient, tex, orient,
				CreateColor(c1[1], c1[2], c1[3], a1),
				CreateColor(c2[1], c2[2], c2[3], a2))
		end
	end
	if not painted and tex.SetGradientAlpha then
		-- Classic path: base color + per-stop alpha.
		tex:SetColorTexture(1, 1, 1, 1)
		painted = pcall(tex.SetGradientAlpha, tex, orient,
			c1[1], c1[2], c1[3], a1, c2[1], c2[2], c2[3], a2)
	end
	if not painted and CreateColor and tex.SetGradient then
		tex:SetColorTexture(1, 1, 1, 1)
		painted = pcall(tex.SetGradient, tex, orient,
			CreateColor(c1[1], c1[2], c1[3], a1),
			CreateColor(c2[1], c2[2], c2[3], a2))
	end
	if not painted then
		-- Guaranteed on Forever: SetColorTexture accepts alpha (0..1).
		tex:SetColorTexture(
			(c1[1] + c2[1]) / 2,
			(c1[2] + c2[2]) / 2,
			(c1[3] + c2[3]) / 2,
			(a1 + a2) / 2
		)
	end
end

local function ColorWithAlpha(c, alpha)
	return { c[1], c[2], c[3], (c[4] or 1) * (alpha or 1) }
end

function W.StripedBackground(frame, style, layer, alpha)
	alpha = alpha or W.LIST_ALPHA or 1
	local c = W.COLORS[style] or W.COLORS.dark
	local left = frame._stripeLeft or frame:CreateTexture(nil, layer or "BACKGROUND")
	local right = frame._stripeRight or frame:CreateTexture(nil, layer or "BACKGROUND")
	left:ClearAllPoints()
	right:ClearAllPoints()
	left:SetPoint("TOPLEFT")
	left:SetPoint("BOTTOMRIGHT", frame, "BOTTOM")
	right:SetPoint("TOPLEFT", frame, "TOP")
	right:SetPoint("BOTTOMRIGHT")
	W.Gradient(left, ColorWithAlpha(c.edge, alpha), ColorWithAlpha(c.center, alpha))
	W.Gradient(right, ColorWithAlpha(c.center, alpha), ColorWithAlpha(c.edge, alpha))
	-- Keep region alpha at 1 so we don't double-multiply with baked color alpha.
	left:SetAlpha(1)
	right:SetAlpha(1)
	frame._stripeLeft = left
	frame._stripeRight = right
	frame._stripeAlpha = alpha
	return left, right
end

function W.RowBackground(row, idx, alpha)
	return W.StripedBackground(row, (idx % 2 == 1) and "light" or "dark", nil, alpha or W.LIST_ALPHA)
end

function W.ApplyHeaderBand(frame, alpha)
	alpha = alpha or W.LIST_ALPHA or 0.5
	if frame._headerBand and frame._stripeLeft then
		-- Re-paint if alpha changed (e.g. after LIST_ALPHA tweak).
		if frame._stripeAlpha ~= alpha then
			W.StripedBackground(frame, "header", nil, alpha)
		end
		return frame._headerBand
	end
	W.StripedBackground(frame, "header", nil, alpha)
	frame._headerBand = true
	return true
end

-- Floating dialogs / menus. Prefer gold dialog border (visible on dark fills);
-- tooltip border often disappears against near-black panels on Forever.
function W.Backdrop(frame, a, style)
	if not frame.SetBackdrop then
		return false
	end
	local edge = (style == "dialog")
		and "Interface\\DialogFrame\\UI-DialogBox-Gold-Border"
		or "Interface\\Tooltips\\UI-Tooltip-Border"
	local edgeSize = (style == "dialog") and 32 or 16
	local inset = (style == "dialog") and 11 or 4
	local ok = pcall(frame.SetBackdrop, frame, {
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = edge,
		tile = true,
		tileSize = 32,
		edgeSize = edgeSize,
		insets = { left = inset, right = inset, top = inset, bottom = inset },
	})
	if not ok then
		return false
	end
	local p = W.COLORS.pane
	pcall(frame.SetBackdropColor, frame, p[1], p[2], p[3], a or 0.96)
	if style == "dialog" then
		local g = W.COLORS.gold
		pcall(frame.SetBackdropBorderColor, frame, g[1], g[2], g[3], 1)
	else
		local b = W.COLORS.border
		pcall(frame.SetBackdropBorderColor, frame, b[1] + 0.15, b[2] + 0.12, b[3] + 0.08, 1)
	end
	return true
end

function W.RegisterSpecialFrame(name)
	if not name or not UISpecialFrames then
		return
	end
	for _, n in ipairs(UISpecialFrames) do
		if n == name then
			return
		end
	end
	tinsert(UISpecialFrames, name)
end

-- Named dialog: dialog-box chrome only, Escape closes (UISpecialFrames + OnKeyDown).
function W.DialogFrame(name, width, height)
	local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
	f:SetSize(width or 380, height or 280)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)

	W.Backdrop(f, 0.96, "dialog")

	W.RegisterSpecialFrame(name)

	if f.EnableKeyboard then
		f:EnableKeyboard(true)
	end
	f:HookScript("OnShow", function(self)
		self:Raise()
		if self.EnableKeyboard then
			self:EnableKeyboard(true)
		end
	end)
	f:SetScript("OnKeyDown", function(self, key)
		if key == "ESCAPE" then
			if self.SetPropagateKeyboardInput then
				pcall(self.SetPropagateKeyboardInput, self, false)
			end
			self:Hide()
			return
		end
		if self.SetPropagateKeyboardInput then
			pcall(self.SetPropagateKeyboardInput, self, true)
		end
	end)

	return f
end

function W.AddInset(parent, x1, y1, x2, y2, anchorTop, paneAlpha)
	local C = W.COLORS
	local bg = parent:CreateTexture(nil, "BACKGROUND", nil, 2)
	-- Keep the well mostly clear so 50% row stripes can show the log scene.
	bg:SetColorTexture(C.pane[1], C.pane[2], C.pane[3], paneAlpha or 0.33)
	bg:SetPoint("TOPLEFT", anchorTop or parent, "TOPLEFT", x1, y1)
	bg:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", x2, y2)

	local inset
	if TemplateExists("InsetFrameTemplate") then
		inset = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
		inset:SetAllPoints(bg)
		inset:SetFrameLevel((parent:GetFrameLevel() or 1) + 8)
		if type(inset.Bg) == "table" then
			inset.Bg:Hide()
		end
		-- NineSlice / border pieces can still paint an opaque fill — clear them.
		if type(inset.NineSlice) == "table" and inset.NineSlice.SetCenterColor then
			pcall(inset.NineSlice.SetCenterColor, inset.NineSlice, 0, 0, 0, 0)
		end
		inset:EnableMouse(false)
	else
		local function edge(p1, p2, horiz)
			local t = parent:CreateTexture(nil, "BACKGROUND", nil, 3)
			t:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
			t:SetPoint(p1, bg, p1)
			t:SetPoint(p2, bg, p2)
			if horiz then
				t:SetHeight(1)
			else
				t:SetWidth(1)
			end
		end
		edge("TOPLEFT", "TOPRIGHT", true)
		edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
		edge("TOPLEFT", "BOTTOMLEFT", false)
		edge("TOPRIGHT", "BOTTOMRIGHT", false)
	end
	return bg, inset
end

function W.MenuButton(parent, w, h, text)
	local tpl = "UIPanelButtonTemplate"
	for _, t in ipairs({ "MainMenuFrameButtonTemplate", "GameMenuButtonTemplate" }) do
		if TemplateExists(t) then
			tpl = t
			break
		end
	end
	local b = CreateFrame("Button", nil, parent, tpl)
	b:SetSize(w or 100, h or 22)
	if tpl ~= "UIPanelButtonTemplate" then
		pcall(b.SetNormalFontObject, b, "GameFontHighlight")
		pcall(b.SetHighlightFontObject, b, "GameFontHighlight")
		pcall(b.SetDisabledFontObject, b, "GameFontDisable")
	end
	if text then
		b:SetText(text)
	end
	return b
end

function W.Button(parent, text, width, height)
	return W.MenuButton(parent, width or 100, height or 22, text or "")
end

function W.IconPath(icon)
	if not icon then
		return "Interface\\Icons\\INV_Misc_QuestionMark"
	end
	if type(icon) == "number" then
		return icon
	end
	if icon:find("\\") or icon:find("/") then
		return icon
	end
	return "Interface\\Icons\\" .. icon
end

function W.SideTab(parent, size)
	local b = CreateFrame("Button", nil, parent)
	if AtlasExists("common-sidetab") then
		size = size or 54
		local k = size / 54
		b:SetSize(size, size)
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetAtlas("common-sidetab")
		b.bg:SetSize(54 * k, 60 * k)
		b.bg:SetPoint("CENTER")
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetSize(50 * k, 50 * k)
		b.icon:SetPoint("CENTER", -4 * k, 0)
		b.icon:SetTexCoord(0.03, 0.97, 0.03, 0.97)
		if b.CreateMaskTexture and AtlasExists("common-sidetab-mask") then
			local m = b:CreateMaskTexture()
			m:SetAtlas("common-sidetab-mask")
			m:SetSize(54 * k, 60 * k)
			m:SetPoint("CENTER")
			b.icon:AddMaskTexture(m)
			b.mask = m
		end
		b.sel = b:CreateTexture(nil, "OVERLAY")
		b.sel:SetAtlas("common-sidetab-selected")
		b.sel:SetSize(54 * k, 60 * k)
		b.sel:SetPoint("CENTER")
		b.sel:Hide()
		b.hl = b:CreateTexture(nil, "HIGHLIGHT")
		b.hl:SetAtlas("common-sidetab-hover")
		b.hl:SetSize(54 * k, 60 * k)
		b.hl:SetPoint("CENTER")
		b.style = "forever"
	else
		size = size or 40
		b:SetSize(size, size)
		b.bg = b:CreateTexture(nil, "BACKGROUND")
		b.bg:SetPoint("TOPLEFT", 1, -1)
		b.bg:SetPoint("BOTTOMRIGHT", -1, 1)
		b.bg:SetColorTexture(0, 0, 0, 0.85)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetPoint("TOPLEFT", 3, -3)
		b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
		b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		b.border = b:CreateTexture(nil, "OVERLAY")
		if AtlasExists("UI-HUD-ActionBar-IconFrame") then
			b.border:SetAtlas("UI-HUD-ActionBar-IconFrame")
			b.border:SetPoint("TOPLEFT", -1, 1)
			b.border:SetPoint("BOTTOMRIGHT", 1, -1)
		else
			b.border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
			b.border:SetSize(size * 1.72, size * 1.72)
			b.border:SetPoint("CENTER", 0, 0)
		end
		b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
		b.sel = b:CreateTexture(nil, "OVERLAY", nil, 2)
		b.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		b.sel:SetBlendMode("ADD")
		b.sel:SetAllPoints()
		b.sel:Hide()
		b.style = "addon"
	end
	b:SetScript("OnEnter", function(self)
		if not self.tooltip then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.tooltip, W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])
		if self.tooltipSub then
			GameTooltip:AddLine(self.tooltipSub, 0.6, 0.6, 0.6)
		end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	function b:SetIcon(icon)
		self.icon:SetTexture(W.IconPath(icon))
	end
	function b:SetActive(on)
		if on then
			self.sel:Show()
		else
			self.sel:Hide()
		end
	end
	return b
end

function W.CreateScrollFrame(parent, name)
	if ScrollUtil and ScrollUtil.InitScrollFrameWithScrollBar and TemplateExists("MinimalScrollBar") then
		local sf = CreateFrame("ScrollFrame", name, parent)
		-- Parent the bar to the scroll frame so Hide()/SetShown() keeps them in sync.
		local okB, bar = pcall(CreateFrame, "EventFrame", nil, sf, "MinimalScrollBar")
		if okB and bar then
			bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 5, -2)
			bar:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 5, 2)
			pcall(ScrollUtil.InitScrollFrameWithScrollBar, sf, bar)
			sf.ScrollBar = bar
			sf._minimal = true
			return sf
		end
	end
	return CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
end

function W.Checkbox(parent, label)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetSize(24, 24)
	c.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	c.label:SetPoint("LEFT", c, "RIGHT", 4, 0)
	c.label:SetText(label or "")
	return c
end

function W.EditBox(parent, width, height)
	local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	e:SetSize(width or 120, height or 20)
	e:SetAutoFocus(false)
	e:SetFontObject(GameFontHighlight)
	e:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	return e
end

-- Shared open-dropdown state: only one menu at a time.
-- Dismiss via fullscreen click-catcher + GLOBAL_MOUSE_DOWN on the menu frame.
local activeDropdown = nil
local dropdownCatcher
local allDropdowns = {}

function W.CloseActiveDropdown()
	local dd = activeDropdown
	activeDropdown = nil
	if dropdownCatcher then
		dropdownCatcher:Hide()
	end
	if dd and dd.menu then
		if dd.menu.UnregisterEvent then
			pcall(dd.menu.UnregisterEvent, dd.menu, "GLOBAL_MOUSE_DOWN")
		end
		dd.menu:Hide()
		dd.menu.owner = nil
	end
end

local function EnsureDropdownCatcher()
	if dropdownCatcher then
		return dropdownCatcher
	end
	local catcher = CreateFrame("Button", "ForeverLootTrackerDropdownCatcher", UIParent)
	catcher:SetFrameStrata("FULLSCREEN_DIALOG")
	catcher:SetFrameLevel(1)
	catcher:SetAllPoints(UIParent)
	catcher:EnableMouse(true)
	catcher:RegisterForClicks("AnyUp")
	catcher:Hide()
	catcher:SetScript("OnMouseUp", function()
		local current = activeDropdown
		local reopen = nil
		for i = #allDropdowns, 1, -1 do
			local other = allDropdowns[i]
			if other and other ~= current and other:IsShown() and other:IsMouseOver() then
				reopen = other
				break
			end
		end
		W.CloseActiveDropdown()
		if reopen and reopen.OpenMenu then
			if C_Timer and C_Timer.After then
				C_Timer.After(0, function()
					if reopen:IsShown() then
						reopen:OpenMenu()
					end
				end)
			else
				reopen:OpenMenu()
			end
		end
	end)
	dropdownCatcher = catcher
	return catcher
end

-- options: { { value = ..., text = "..." }, ... }
-- onChange(value, text)
function W.Dropdown(parent, width, options, onChange)
	local dd = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	dd:SetSize(width or 160, 24)
	W.Backdrop(dd, 0.9)
	table.insert(allDropdowns, dd)

	dd.button = CreateFrame("Button", nil, dd)
	dd.button:SetAllPoints()
	dd.button:RegisterForClicks("LeftButtonUp")

	dd.text = dd.button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dd.text:SetPoint("LEFT", 8, 0)
	dd.text:SetPoint("RIGHT", -20, 0)
	dd.text:SetJustifyH("LEFT")
	dd.text:SetText("Select...")

	dd.arrow = dd.button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	dd.arrow:SetPoint("RIGHT", -6, 0)
	dd.arrow:SetText("v")

	dd.value = nil
	dd.options = options or {}
	dd.onChange = onChange

	local menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	menu:SetFrameLevel(100)
	menu:SetClampedToScreen(true)
	menu:EnableMouse(true)
	W.Backdrop(menu, 0.98)
	menu:Hide()
	menu.buttons = {}
	dd.menu = menu

	local function CloseMenu()
		if activeDropdown == dd then
			W.CloseActiveDropdown()
		else
			if menu.UnregisterEvent then
				pcall(menu.UnregisterEvent, menu, "GLOBAL_MOUSE_DOWN")
			end
			menu:Hide()
			menu.owner = nil
		end
	end

	local function RebuildMenu()
		for _, b in ipairs(menu.buttons) do
			b:Hide()
		end
		local y = -4
		local maxW = dd:GetWidth()
		for i, opt in ipairs(dd.options) do
			local b = menu.buttons[i]
			if not b then
				b = CreateFrame("Button", nil, menu, "BackdropTemplate")
				b:SetHeight(22)
				b:SetPoint("LEFT", 4, 0)
				b:SetPoint("RIGHT", -4, 0)
				b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				b.label:SetPoint("LEFT", 6, 0)
				b.label:SetPoint("RIGHT", -6, 0)
				b.label:SetJustifyH("LEFT")
				b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
				b:SetScript("OnClick", function(self)
					dd:SetValue(self.optValue, true)
					CloseMenu()
				end)
				menu.buttons[i] = b
			end
			b.optValue = opt.value
			b.label:SetText(opt.text or tostring(opt.value))
			b:ClearAllPoints()
			b:SetPoint("TOPLEFT", 4, y)
			b:SetPoint("TOPRIGHT", -4, y)
			b:Show()
			y = y - 22
		end
		menu:SetSize(maxW, math.max(28, -y + 8))
	end

	local function OpenMenu()
		if activeDropdown and activeDropdown ~= dd then
			W.CloseActiveDropdown()
		end
		if activeDropdown == dd and menu:IsShown() then
			return
		end
		RebuildMenu()
		local catcher = EnsureDropdownCatcher()
		catcher:SetFrameLevel(1)
		catcher:Show()
		menu:SetFrameLevel(100)
		menu.owner = dd
		menu:ClearAllPoints()
		menu:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
		menu:Show()
		activeDropdown = dd

		menu:SetScript("OnEvent", function(self, event)
			if event ~= "GLOBAL_MOUSE_DOWN" or not self:IsShown() then
				return
			end
			if self:IsMouseOver() or dd:IsMouseOver() then
				return
			end
			CloseMenu()
		end)
		if menu.RegisterEvent then
			pcall(menu.RegisterEvent, menu, "GLOBAL_MOUSE_DOWN")
		end
	end

	dd.OpenMenu = OpenMenu

	function dd:SetOptions(newOptions)
		self.options = newOptions or {}
		RebuildMenu()
	end

	function dd:SetValue(value, fire)
		self.value = value
		local label = "Select..."
		for _, opt in ipairs(self.options) do
			if opt.value == value or (opt.value == nil and value == nil) then
				label = opt.text
				break
			end
		end
		if label == "Select..." then
			for _, opt in ipairs(self.options) do
				if tostring(opt.value) == tostring(value) then
					label = opt.text
					self.value = opt.value
					break
				end
			end
		end
		self.text:SetText(label)
		if fire and self.onChange then
			self.onChange(self.value, label)
		end
	end

	function dd:GetValue()
		return self.value
	end

	function dd:Close()
		CloseMenu()
	end

	dd.button:SetScript("OnClick", function()
		if activeDropdown == dd and menu:IsShown() then
			CloseMenu()
			return
		end
		OpenMenu()
	end)

	menu:SetScript("OnHide", function()
		if menu.UnregisterEvent then
			pcall(menu.UnregisterEvent, menu, "GLOBAL_MOUSE_DOWN")
		end
		if activeDropdown == dd then
			activeDropdown = nil
			if dropdownCatcher then
				dropdownCatcher:Hide()
			end
		end
		menu.owner = nil
	end)

	dd:SetScript("OnHide", CloseMenu)

	RebuildMenu()
	return dd
end

function W.RadioGroup(parent, radios, onChange)
	local group = CreateFrame("Frame", nil, parent)
	group.buttons = {}
	group.value = nil
	group.onChange = onChange

	local x = 0
	for i, opt in ipairs(radios) do
		local r = CreateFrame("CheckButton", nil, group, "UIRadioButtonTemplate")
		r:SetSize(16, 16)
		r:SetPoint("LEFT", x, 0)
		r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.label:SetPoint("LEFT", r, "RIGHT", 2, 0)
		r.label:SetText(opt.text)
		r.value = opt.value
		r:SetScript("OnClick", function(self)
			group:SetValue(self.value, true)
		end)
		group.buttons[i] = r
		x = x + (opt.width or 90)
	end
	group:SetSize(x, 20)

	function group:SetValue(value, fire)
		self.value = value
		for _, b in ipairs(self.buttons) do
			b:SetChecked(b.value == value)
		end
		if fire and self.onChange then
			self.onChange(value)
		end
	end

	function group:GetValue()
		return self.value
	end

	return group
end
