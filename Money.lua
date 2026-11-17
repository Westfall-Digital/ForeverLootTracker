-- ForeverLootTracker — wallet gain/loss capture (Accountant-style).
-- Primary signal: PLAYER_MONEY + GetMoney() delta.
-- Cause comes from which service UI was open (vendor / repair / flight / trainer / …).
local FLT = ForeverLootTracker

local moneyMode = nil -- sticky cause key while a service UI is active
local moneyDetail = nil -- optional NPC / note
local lastMoney = nil
local suppressUntil = 0 -- clear sticky modes shortly after a delayed money event
-- One-shot AH action set by API hooks (listing deposit vs buyout/bid).
local pendingAuctionAction = nil -- "ListingFee" | "Purchase" | "Cancel"
local pendingAuctionDetail = nil
local pendingAuctionUntil = 0

local MODE_LABEL = {
	Loot = "Loot",
	Vendor = "Vendor",
	Repair = "Repair",
	Flight = "Flight Path",
	Training = "Training",
	Trade = "Trade",
	Mail = "Mail",
	Auction = "Auction House",
	Quest = "Quest",
	Bank = "Bank",
	GuildBank = "Guild Bank",
	Barber = "Barber",
	Other = "Other",
}

local function ReadableName(unit)
	if not unit then
		return nil
	end
	local name = UnitName(unit)
	if name and issecretvalue and issecretvalue(name) then
		return nil
	end
	if name == "" then
		return nil
	end
	return name
end

local function CurrentNpc()
	if FLT.UnitDisplayName then
		return FLT.UnitDisplayName("npc") or FLT.UnitDisplayName("target") or ReadableName("npc") or ReadableName("target")
	end
	return ReadableName("npc") or ReadableName("target")
end

function FLT.GetActiveVendorName()
	local mode, detail = FLT.GetMoneyMode()
	if mode == "Vendor" and detail and detail ~= "" and detail ~= "Vendor" then
		return detail
	end
	if FLT.lastSourceKind == "Vendor" and FLT.lastSource and FLT.lastSource ~= "" and FLT.lastSource ~= "Vendor" then
		return FLT.lastSource
	end
	return CurrentNpc()
end

function FLT.IsVendorPurchaseContext()
	local mode = FLT.GetMoneyMode()
	if mode == "Vendor" then
		return true
	end
	if MerchantFrame and MerchantFrame.IsShown and MerchantFrame:IsShown() then
		return true
	end
	return false
end

-- Bank / guild-bank bag moves fire the same "You receive item:" chat as loot — never track them.
function FLT.IsBankTransferContext()
	local mode = FLT.GetMoneyMode()
	if mode == "Bank" or mode == "GuildBank" then
		return true
	end
	if BankFrame and BankFrame.IsShown and BankFrame:IsShown() then
		return true
	end
	if GuildBankFrame and GuildBankFrame.IsShown and GuildBankFrame:IsShown() then
		return true
	end
	return false
end

-- Money: mailbox open or short post-close sticky (PLAYER_MONEY can lag the frame).
function FLT.IsMailContext()
	local mode = FLT.GetMoneyMode()
	if mode == "Mail" then
		return true
	end
	if FLT.mailStickyUntil and GetTime() < FLT.mailStickyUntil then
		return true
	end
	if MailFrame and MailFrame.IsShown and MailFrame:IsShown() then
		return true
	end
	if InboxFrame and InboxFrame.IsShown and InboxFrame:IsShown() then
		return true
	end
	return false
end

-- Quest starter/reward items also use LOOT_ITEM_PUSHED_SELF ("You receive item:"),
-- the same chat as mailbox attachments — quest context must win over mail.
function FLT.IsQuestItemContext()
	if FLT.ExpireMoneyModeIfNeeded then
		FLT.ExpireMoneyModeIfNeeded()
	end
	if FLT.questItemStickyUntil and GetTime() < FLT.questItemStickyUntil then
		return true
	end
	local mode = FLT.GetMoneyMode()
	if mode == "Quest" then
		return true
	end
	-- Only the accept/turn-in dialog — NOT the quest log (browsing while farming).
	if QuestFrame and QuestFrame.IsShown and QuestFrame:IsShown() then
		return true
	end
	return false
end

function FLT.NoteQuestItemContext(seconds, detail)
	seconds = tonumber(seconds) or 5
	FLT.questItemStickyUntil = GetTime() + seconds
	-- Quest pushes must not inherit a leftover Mailbox / DE label.
	FLT.mailItemStickyUntil = nil
	FLT.mailStickyUntil = nil
	if FLT.ClearDisenchantSticky then
		FLT.ClearDisenchantSticky()
	end
	FLT.lastSource = detail or "Quest"
	FLT.lastSourceKind = "Quest"
	FLT.Debug("Quest item context (" .. tostring(seconds) .. "s)")
end

-- Items: only while the mailbox UI is actually open, or the short post-close sticky.
-- Do NOT use moneyMode=="Mail" alone — a stuck mode stole quest/vendor bag pushes.
-- Do NOT use the multi-second money sticky — that stole Disenchant shards after mail.
function FLT.IsMailItemContext()
	if FLT.IsQuestItemContext and FLT.IsQuestItemContext() then
		return false
	end
	if MailFrame and MailFrame.IsShown and MailFrame:IsShown() then
		return true
	end
	if InboxFrame and InboxFrame.IsShown and InboxFrame:IsShown() then
		-- Some UIs leave InboxFrame "shown" while hidden; require mail mode or sticky too.
		if (MailFrame and MailFrame.IsShown and MailFrame:IsShown())
			or FLT.GetMoneyMode() == "Mail"
			or (FLT.mailItemStickyUntil and GetTime() < FLT.mailItemStickyUntil) then
			return true
		end
	end
	if FLT.mailItemStickyUntil and GetTime() < FLT.mailItemStickyUntil then
		return true
	end
	return false
end

function FLT.SetMoneyMode(mode, detail, stickySeconds)
	moneyMode = mode
	moneyDetail = detail or CurrentNpc()
	if stickySeconds and stickySeconds > 0 then
		suppressUntil = GetTime() + stickySeconds
	else
		suppressUntil = 0
	end
	FLT.Debug("Money mode → " .. tostring(mode) .. (moneyDetail and (" (" .. moneyDetail .. ")") or ""))
end

function FLT.ClearMoneyMode(expected)
	if expected and moneyMode ~= expected then
		return
	end
	moneyMode = nil
	moneyDetail = nil
	suppressUntil = 0
end

-- Expire abandoned sticky modes (cancelled flight, quest with no coin, stale AH, etc.).
function FLT.ExpireMoneyModeIfNeeded()
	if suppressUntil <= 0 or GetTime() <= suppressUntil then
		return
	end
	if moneyMode == "Flight" or moneyMode == "Loot" or moneyMode == "Quest"
		or moneyMode == "Auction" or moneyMode == "Trade" then
		FLT.Debug("Money mode expired: " .. tostring(moneyMode))
		moneyMode = nil
		moneyDetail = nil
		suppressUntil = 0
	end
end

function FLT.GetMoneyMode()
	FLT.ExpireMoneyModeIfNeeded()
	return moneyMode, moneyDetail
end

local function TakePendingAuction()
	if not pendingAuctionAction then
		return nil, nil
	end
	if pendingAuctionUntil > 0 and GetTime() > pendingAuctionUntil then
		pendingAuctionAction = nil
		pendingAuctionDetail = nil
		pendingAuctionUntil = 0
		return nil, nil
	end
	local action, detail = pendingAuctionAction, pendingAuctionDetail
	pendingAuctionAction = nil
	pendingAuctionDetail = nil
	pendingAuctionUntil = 0
	return action, detail
end

local function SetPendingAuction(action, detail)
	pendingAuctionAction = action
	pendingAuctionDetail = detail
	pendingAuctionUntil = GetTime() + 8
	FLT.SetMoneyMode("Auction", detail, 8)
	FLT.Debug("AH pending → " .. tostring(action) .. (detail and (" (" .. detail .. ")") or ""))
end

local function AuctionItemNameFromSellSlot()
	if not GetAuctionSellItemInfo then
		return nil
	end
	local ok, name = pcall(GetAuctionSellItemInfo)
	if ok and name and name ~= "" then
		return name
	end
	return nil
end

local function AuctionItemNameFromList(listType, index)
	if not GetAuctionItemInfo then
		return nil
	end
	local ok, name = pcall(GetAuctionItemInfo, listType, index)
	if ok and name and name ~= "" then
		return name
	end
	return nil
end

local function ResolveCause(delta)
	local auctionAction, auctionDetail = TakePendingAuction()
	local mode = moneyMode
	-- Repair detection: merchant repair mode or recent RepairAllItems hook.
	if (not mode or mode == "Vendor") and InRepairMode and InRepairMode() then
		mode = "Repair"
	end
	if auctionAction then
		mode = "Auction"
	end
	if (not mode or mode == "") and FLT.IsMailContext and FLT.IsMailContext() then
		mode = "Mail"
	end
	if not mode or mode == "" then
		mode = "Other"
	end

	local label = MODE_LABEL[mode] or mode
	local detail = auctionDetail or moneyDetail or CurrentNpc()

	if mode == "Vendor" then
		if delta > 0 then
			label = "Vendor Sale"
		else
			label = "Vendor Purchase"
		end
	elseif mode == "Repair" then
		label = "Repair"
	elseif mode == "Flight" then
		label = "Flight Path"
	elseif mode == "Training" then
		label = "Training"
	elseif mode == "Loot" then
		label = "Loot"
	elseif mode == "Quest" then
		label = delta >= 0 and "Quest Reward" or "Quest"
	elseif mode == "Trade" then
		label = delta >= 0 and "Trade Received" or "Trade Given"
	elseif mode == "Mail" then
		-- AH sale proceeds usually arrive as mail; keep Mail unless subject parsing is added later.
		label = delta >= 0 and "Mail Received" or "Mail Sent"
	elseif mode == "Auction" then
		if auctionAction == "ListingFee" then
			label = "Auction Listing Fee"
		elseif auctionAction == "Purchase" then
			label = delta < 0 and "Auction Purchase" or "Auction Refund"
		elseif auctionAction == "Cancel" then
			label = delta > 0 and "Auction Deposit Refund" or "Auction Cancel"
		elseif delta > 0 then
			label = "Auction Sale"
		else
			-- Spend while AH is open without a specific hook → treat as purchase.
			label = "Auction Purchase"
		end
	end

	if detail and detail ~= "" then
		label = label .. ": " .. detail
	end
	return mode, label
end

local function ConsumeStickyMode(mode)
	-- Taxi / loot / quest / AH / trade UIs often close before PLAYER_MONEY fires.
	if mode == "Flight" or mode == "Loot" or mode == "Quest"
		or mode == "Auction" or mode == "Trade" or mode == "Mail" then
		moneyMode = nil
		moneyDetail = nil
		suppressUntil = 0
	elseif mode == "Repair" then
		-- After a repair, merchant may still be open for shopping.
		moneyMode = "Vendor"
		suppressUntil = 0
	end
end

function FLT.InitMoneyTracker()
	local ok, value = pcall(GetMoney)
	if ok then
		lastMoney = value
	end
	FLT.HookMoneyRepair()
	FLT.HookAuctionHouse()
end

function FLT.OnPlayerMoney()
	local ok, current = pcall(GetMoney)
	if not ok or current == nil then
		return
	end
	if lastMoney == nil then
		lastMoney = current
		return
	end
	local delta = current - lastMoney
	lastMoney = current
	if delta == 0 then
		return
	end

	FLT.ExpireMoneyModeIfNeeded()

	local mode, label = ResolveCause(delta)
	FLT.AddMoneyRecord(delta, label, mode)
	ConsumeStickyMode(mode)
end

-- CHAT_MSG_MONEY is context only — actual copper comes from PLAYER_MONEY.
function FLT.OnChatMoney(_text)
	FLT.SetMoneyMode("Loot", nil, 3)
end

function FLT.HookMoneyRepair()
	if FLT._repairHooked then
		return
	end
	if type(RepairAllItems) == "function" then
		local original = RepairAllItems
		RepairAllItems = function(...)
			FLT.SetMoneyMode("Repair", CurrentNpc())
			return original(...)
		end
		FLT._repairHooked = true
	end
end

-- Distinguish AH listing deposits from buyouts/bids (Classic StartAuction / PlaceAuctionBid,
-- plus modern C_AuctionHouse when present). Blizzard_AuctionUI may load late — retry on SHOW.
function FLT.HookAuctionHouse()
	if FLT._ahHooksDone then
		return true
	end
	local hooked = false

	local function wrap(globalName, action, detailFn)
		local fn = _G[globalName]
		if type(fn) ~= "function" or FLT["_ah_" .. globalName] then
			return
		end
		FLT["_ah_" .. globalName] = true
		_G[globalName] = function(...)
			local detail = detailFn and detailFn(...) or nil
			SetPendingAuction(action, detail)
			return fn(...)
		end
		hooked = true
	end

	-- Classic / Forever listing → deposit (listing fee).
	wrap("StartAuction", "ListingFee", function()
		return AuctionItemNameFromSellSlot()
	end)
	wrap("PostAuction", "ListingFee", function()
		return AuctionItemNameFromSellSlot()
	end)
	-- Classic bid / buyout.
	wrap("PlaceAuctionBid", "Purchase", function(listType, index)
		return AuctionItemNameFromList(listType, index)
	end)
	wrap("CancelAuction", "Cancel", function(index)
		return AuctionItemNameFromList("owner", index)
	end)

	-- Modern C_AuctionHouse (if Forever exposes it for purchases/posts).
	if C_AuctionHouse then
		local function wrapMethod(tbl, name, action, detailFn)
			local fn = tbl[name]
			if type(fn) ~= "function" or FLT["_ah_C_" .. name] then
				return
			end
			FLT["_ah_C_" .. name] = true
			tbl[name] = function(...)
				local detail = detailFn and detailFn(...) or nil
				SetPendingAuction(action, detail)
				return fn(...)
			end
			hooked = true
		end
		wrapMethod(C_AuctionHouse, "PostAuction", "ListingFee")
		wrapMethod(C_AuctionHouse, "PostCommodity", "ListingFee")
		wrapMethod(C_AuctionHouse, "PlaceBid", "Purchase")
		wrapMethod(C_AuctionHouse, "ConfirmCommoditiesPurchase", "Purchase")
		wrapMethod(C_AuctionHouse, "StartCommoditiesPurchase", "Purchase")
		wrapMethod(C_AuctionHouse, "CancelAuction", "Cancel")
	end

	if hooked then
		FLT._ahHooksDone = true
		FLT.Debug("Auction House money hooks installed.")
	end
	return hooked
end

-- Event routing for money-cause windows (called from Core).
function FLT.OnMoneyContextEvent(event, ...)
	if event == "MERCHANT_SHOW" then
		local vendor = CurrentNpc()
		if InRepairMode and InRepairMode() then
			FLT.SetMoneyMode("Repair", vendor)
		else
			FLT.SetMoneyMode("Vendor", vendor)
			-- Prefer the merchant's name as item source (not a sticky kill target).
			FLT.lastSource = vendor or "Vendor"
			FLT.lastSourceKind = "Vendor"
		end
	elseif event == "MERCHANT_CLOSED" then
		FLT.ClearMoneyMode()
		if FLT.lastSourceKind == "Vendor" or FLT.lastSource == "Vendor" then
			FLT.lastSource = "Unknown"
			FLT.lastSourceKind = nil
		end
	elseif event == "TAXIMAP_OPENED" then
		FLT.SetMoneyMode("Flight", CurrentNpc(), 8)
	elseif event == "TAXIMAP_CLOSED" then
		-- Keep Flight sticky — map closes before the fare is charged.
		suppressUntil = GetTime() + 8
	elseif event == "TRAINER_SHOW" then
		FLT.SetMoneyMode("Training", CurrentNpc())
	elseif event == "TRAINER_CLOSED" then
		FLT.ClearMoneyMode("Training")
	elseif event == "TRADE_SHOW" then
		FLT.SetMoneyMode("Trade", nil, 5)
	elseif event == "TRADE_CLOSED" then
		-- Keep briefly — PLAYER_MONEY can lag the frame close.
		suppressUntil = GetTime() + 3
	elseif event == "MAIL_SHOW" then
		FLT.SetMoneyMode("Mail")
		FLT.lastSource = "Mailbox"
		FLT.lastSourceKind = "Mail"
		FLT.mailStickyUntil = nil
		FLT.mailItemStickyUntil = nil
		if FLT.ClearDisenchantSticky then
			FLT.ClearDisenchantSticky()
		end
	elseif event == "MAIL_CLOSED" then
		-- Keep Mail money mode briefly — PLAYER_MONEY can lag the frame close.
		FLT.SetMoneyMode("Mail", nil, 3)
		FLT.mailStickyUntil = GetTime() + 3
		FLT.mailItemStickyUntil = GetTime() + 0.75
		if C_Timer and C_Timer.After then
			C_Timer.After(0.8, function()
				if FLT.lastSourceKind == "Mail" and not (FLT.IsMailItemContext and FLT.IsMailItemContext()) then
					FLT.lastSource = "Unknown"
					FLT.lastSourceKind = nil
				end
			end)
		end
	elseif event == "AUCTION_HOUSE_SHOW" then
		FLT.HookAuctionHouse()
		FLT.SetMoneyMode("Auction", nil, 8)
	elseif event == "AUCTION_HOUSE_CLOSED" then
		-- Keep a short sticky window so a late PLAYER_MONEY still attributes to AH.
		if pendingAuctionAction then
			pendingAuctionUntil = GetTime() + 8
			suppressUntil = GetTime() + 8
		else
			suppressUntil = GetTime() + 3
			-- Leave mode set until suppressUntil expires via ExpireMoneyModeIfNeeded.
		end
	elseif event == "BANKFRAME_OPENED" then
		FLT.SetMoneyMode("Bank")
	elseif event == "BANKFRAME_CLOSED" then
		FLT.ClearMoneyMode("Bank")
	elseif event == "GUILDBANKFRAME_OPENED" then
		FLT.SetMoneyMode("GuildBank")
	elseif event == "GUILDBANKFRAME_CLOSED" then
		FLT.ClearMoneyMode("GuildBank")
	elseif event == "BARBER_SHOP_OPEN" then
		FLT.SetMoneyMode("Barber")
	elseif event == "BARBER_SHOP_CLOSE" then
		FLT.ClearMoneyMode("Barber")
	elseif event == "LOOT_OPENED" then
		if FLT.OnLootOpenedForSource then
			FLT.OnLootOpenedForSource()
		else
			FLT.SetMoneyMode("Loot", nil, 5)
			if FLT.OnLootWindowOpened then
				FLT.OnLootWindowOpened()
			end
		end
	elseif event == "LOOT_CLOSED" then
		suppressUntil = GetTime() + 5
		if FLT.OnLootWindowClosed then
			FLT.OnLootWindowClosed()
		end
	elseif event == "QUEST_DETAIL" then
		-- Accept dialog (starter items grant on accept moments later).
		FLT.NoteQuestItemContext(8, "Quest")
	elseif event == "QUEST_ACCEPTED" then
		FLT.NoteQuestItemContext(5, "Quest")
	elseif event == "QUEST_PROGRESS" then
		FLT.NoteQuestItemContext(4, "Quest")
	elseif event == "QUEST_COMPLETE" or event == "QUEST_TURNED_IN" then
		FLT.SetMoneyMode("Quest", nil, 5)
		FLT.NoteQuestItemContext(5, "Quest")
	elseif event == "QUEST_FINISHED" then
		suppressUntil = GetTime() + 5
		if FLT.questItemStickyUntil and FLT.questItemStickyUntil < GetTime() + 2 then
			FLT.questItemStickyUntil = GetTime() + 2
		end
	elseif event == "ADDON_LOADED" then
		local name = ...
		if name == "Blizzard_AuctionUI" or name == "Blizzard_AuctionHouseUI" then
			FLT.HookAuctionHouse()
		end
	elseif event == "PLAYER_MONEY" then
		FLT.OnPlayerMoney()
	elseif event == "PLAYER_ENTERING_WORLD" then
		FLT.InitMoneyTracker()
	end
end
