local AceAddon = LibStub("AceAddon-3.0")
PICauction = AceAddon:NewAddon("PICauction", "AceConsole-3.0", "AceEvent-3.0")
local REVISION = 1

PICauction.options = {
  name = "PICauction",
  desc = "Run an auction",
  type = "group",
  handler = PICauction,
  args = {
    ["auction"] = {
      type = "input",
      name = "Start Auction",
      desc = "Start an auction for an item",
      usage = "<item>",
      get = false,
      set = "StartBasicAuction",
      pattern = "%w",
    },
    ["end"] = {
      type = "execute",
      name = "End Auction",
      desc = "End current auction and report winner",
      func = "EndAndReport",
    },
    ["status"] = {
      type = "execute",
      name = "Status",
      desc = "Report on current status",
      func = "StatusReport",
    },
  },
}

PICauction.defaults = {
  profile = {
    items = {
      ['*'] = {
        originalbid = nil,
        bid = nil,
      },
    },
  },
}

local channels = {"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER"}

local function filterOutBids(self, event, msg, author, ...)
  -- test to see if we're running an auction now
  if PICauction:HasOngoingAuction() and PICauction:ParseBid(msg, author) then
    return true
  end
end

local function filterOutBidAcks(self, event, msg, ...)
  if string.match(msg, "^!Registered bid ") then
    return true
  end
end

function PICauction:OnInitialize()
  local version = GetAddOnMetadata("PICauction", "Version")
  self.version = string.format("PICauction v%s (r%s)", version, REVISION)

  LibStub("AceConfig-3.0"):RegisterOptionsTable("PICauction", self:GetOptions(), {"pica"} )
  self.db = LibStub("AceDB-3.0"):New("PICauctionDB", PICauction.defaults)

  self:ClearAuction()
end

function PICauction:GetOptions()
  return PICauction.options
end

function PICauction:OnEnable()
  ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterOutBidAcks)
  ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER_INFORM", filterOutBidAcks)
  for i,event in ipairs(channels) do
    ChatFrame_AddMessageEventFilter(event, filterOutBids)
    self:RegisterEvent(event, "HandleBid")
  end
end

function PICauction:OnDisable()
  ChatFrame_RemoveMessageEventFilter("CHAT_MSG_WHISPER_INFORM", filterOutBidAcks)
  ChatFrame_RemoveMessageEventFilter("CHAT_MSG_BN_WHISPER_INFORM", filterOutBidAcks)
  for event in channels do
    ChatFrame_RemoveMessageEventFilter(event, filterOutBids)
    self:UnregisterEvent(event)
  end
end

function PICauction:StartAuction(item, quantity)
  self:ClearAuction()
  self.has_ongoing_auction = true
  self.auctioning_item = item
  self.dutch_quantity = quantity
end

function PICauction:EndAuction()
  self.has_ongoing_auction = false

  local winners = self:GetWinners()
  if #winners > 0 then
    self.db.profile.items[self.auctioning_item].originalbid = winners[1].originalbid
    self.db.profile.items[self.auctioning_item].bid = winners[1].bid
  end
end

function PICauction:Announce(msg)
  if UnitInRaid("player") then
    SendChatMessage(msg, "RAID")
  elseif 0 < GetNumPartyMembers() then
    SendChatMessage(msg, "PARTY")
  else
    self:Print(msg)
  end
end

function PICauction:GetWinners()
  local orderedbids = {}
  for k,v in pairs(self.bids) do table.insert(orderedbids, v) end
  table.sort(orderedbids, function(a,b) return (a.bid > b.bid) end)

  local winners, quantitysum = {}, 0
  for k,v in ipairs(orderedbids) do
    local paybid
    if #orderedbids == k then
      paybid = 0
    else
      paybid = orderedbids[k+1].bid
    end

    table.insert(winners, {
      who = v.who,
      originalbid = v.bid,
      bid = paybid,
      quantity = math.min(self.dutch_quantity - quantitysum, v.quantity)
    })
    quantitysum = quantitysum + v.quantity

    if quantitysum >= self.dutch_quantity then break end
  end

  return winners
end

function PICauction:RegisterBid(who, bid, quantity)
  if not self.bids[who] then
    self.bidcount = self.bidcount + 1
  end
  self.bids[who] = {who = who, bid = bid, quantity = quantity}
end

function PICauction:ClearAuction()
  self.has_ongoing_auction = false
  self.auctioning_item = "nothing"
  self.dutch_quantity = 1
  self.bids = {}
  self.bidcount = 0
end

function PICauction:HasOngoingAuction()
  return self.has_ongoing_auction
end

function PICauction:ReportWinner(reportfunc)
  reportfunc(self, string.format("Auction for %s is over.", self.auctioning_item))
  -- TODO: loop through winners and report
  winners = self:GetWinners()
  if #winners == 0 then
    reportfunc(self, "No one bid on the auction.")
  else
    if 1 == self.dutch_quantity then
      local a = winners[1]
      reportfunc(self, string.format("%s won %s with a bid of %s. %s pays %s", a.who, self.auctioning_item, a.originalbid, a.who, a.bid))
    else
      for k,v in ipairs(winners) do
        reportfunc(self, string.format("%s won %s x %s with a bid of %s. %s pays %s apiece for a total of %s", v.who, v.quantity, self.auctioning_item, v.originalbid, v.who, v.bid, v.quantity * v.bid))
      end
    end
  end
end

----- Interface Commands -------
function PICauction:HandleBid(event, msg, author, arg3, arg4, arg5, arg6, arg7, arg8, arg9, arg10, arg11, arg12, arg13)
  -- look for bid. If present, register it.
  local price, author, quantity = self:ParseBid(msg, author)
  local respondTo = function(txt)
    if "CHAT_MSG_BN_WHISPER" == event then
      BNSendWhisper(arg13, txt)
    else
      SendChatMessage(txt, "WHISPER", nil, author)
    end
  end

  if self:HasOngoingAuction() then
    if price then
      self:RegisterBid(author, price, quantity)

      if self.dutch_quantity == 1 then
        desc = price
      else
        desc = string.format("%d x %s", quantity, price)
      end

      respondTo(string.format("!Registered bid %s for %s. Thank you.",  desc, self.auctioning_item), "WHISPER", nil, author)
    end
  else
    if price then
      respondTo("Bids are over, sorry.", "WHISPER", nil, author)
    end
  end
end

-- price, author, quantity or nil
function PICauction:ParseBid(msg, author)
  quantity, price = string.match(msg, "^%s*!bid%s*(%d+)%s*x%s*(%d+)")
  if quantity then
    return tonumber(price), author, tonumber(quantity)
  end

  price = string.match(msg, "^%s*!bid%s*(%d+)")
  if price then
    return tonumber(price), author, 1
  end

  return nil
end

function PICauction:StartBasicAuction(info, item_spec)
  quantity, item = string.match(item_spec, "^%s*(%d+)%s*x%s*(.+)")
  if quantity then
    self:StartAuction(item, tonumber(quantity))
  else
    self:StartAuction(item_spec, 1)
  end
  self:AnnounceAuction()
end

function PICauction:EndAndReport(info)
  self:EndAuction()
  self:ReportWinner(self.Announce)
end

function PICauction:StatusReport(info)
  if not self:HasOngoingAuction() then
     self:Print("No current auction")
     if string.len(self.auctioning_item) > 0 then
       self:ReportWinner(self.Print)
     end
  else
     local auctiondesc
     if self.dutch_quantity > 1 then
       auctiondesc = string.format("%d x %s", self.dutch_quantity, self.auctioning_item)
     else
       auctiondesc = self.auctioning_item
     end
     self:Print(string.format("Currently auctioning %s. Received %d bids", auctiondesc, self.bidcount))
  end
end

function PICauction:AnnounceAuction()
  -- TODO: auctioneer price, last previous win price
  local auctioneerPrice, lastWin, lastBid, descAuc = nil, nil, nil, ""
  if _G.AucAdvanced then
    auctioneerPrice = AucAdvanced.GetModule("Stat", "Simple").GetPrice(self.auctioning_item)
    if auctioneerPrice and auctioneerPrice > 0 then
      auctioneerPrice = math.floor(auctioneerPrice / 10000)
    else
      auctioneerPrice = nil
    end
  end
  if self.db.profile.items[self.auctioning_item].bid then
    lastBid = self.db.profile.items[self.auctioning_item].originalbid
    lastWin = self.db.profile.items[self.auctioning_item].bid
  end

  if auctioneerPrice then
    descAuc = string.format("%sAuctioneer price for %s: %s. ", descAuc, self.auctioning_item, auctioneerPrice)
  end
  if lastWin then
    descAuc = string.format("%sLast auctioned %s for %s (on a winning bid of %s).", descAuc, self.auctioning_item, lastWin, lastBid)
  end

  local bidformat
  if self.dutch_quantity > 1 then bidformat = '"!bid 2x150"' else bidformat = '"!bid 150"' end
  self:Announce(string.format("Now auctioning: %s. Whisper bids to %s in form %s", self.auctioning_item, GetUnitName("player", false), bidformat))
  if #descAuc > 0 then
    self:Announce(descAuc)
  end
end
