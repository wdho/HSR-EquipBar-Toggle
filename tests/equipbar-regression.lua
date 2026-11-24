-- Offline regression: lua tests/equipbar-regression.lua
-- Loads the production chunk with the same revision prefix as the native worker.
local file=assert(io.open("lua/EquipBarScript.lua","rb"))
local source=file:read("*a")
file:close()

local panel,backpack,equip,consumables,prefs,fail,attempts,saves,nextId
local function event()
  return {
    callbacks={},
    AddListener=function(self,cb) table.insert(self.callbacks,cb) end,
    RemoveListener=function(self,cb)
      for i,c in ipairs(self.callbacks) do if c==cb then table.remove(self.callbacks,i) return end end
    end,
    RemoveAllListeners=function(self) self.callbacks={} end,
    Fire=function(self,...) for _,cb in ipairs(self.callbacks) do cb(...) end end
  }
end

local function object(name)
  nextId=nextId+1
  local obj={name=name,id=nextId,activeSelf=true,parts={}}
  local tr={gameObject=obj,children={},rect={width=1200,height=800,xMin=0,xMax=1200,yMin=0,yMax=800}}
  obj.transform=tr
  setmetatable(obj,{__index=function(self,k)
    if k~="activeInHierarchy" then return end
    if not self.activeSelf then return false end
    return tr.parent==nil or tr.parent.gameObject.activeInHierarchy
  end})
  function tr:Find(n)
    local t=self
    for name in n:gmatch("[^/]+") do
      t=t.children[name]
      if not t then return nil end
    end
    return t
  end
  function tr:SetParent(parent)
    assert(parent.children[name]==nil,"duplicate child: "..name)
    parent.children[name]=self
    self.parent=parent
    self.siblingIndex=parent.childCount or 0
    parent.childCount=(parent.childCount or 0)+1
  end
  function tr:GetChild(i)
    local n=0
    for _,c in pairs(self.children) do
      if n==i then return c end
      n=n+1
    end
    return nil
  end
  function tr:SetAsLastSibling() end
  function tr:GetSiblingIndex() return self.siblingIndex or 0 end
  function tr:SetSiblingIndex(i) self.siblingIndex=i end
  function tr:IsChildOf(parent)
    local t=self.parent
    while t~=nil do
      if t==parent then return true end
      t=t.parent
    end
    return false
  end
  function tr:TransformPoint(v) return {x=v.x+(self.testX or 0),y=v.y+(self.testY or 0),z=v.z} end
  function tr:InverseTransformPoint(v) return v end
  function obj:SetActive(active) self.activeSelf=active end
  function obj:GetInstanceID() return self.id end
  function obj:GetComponentInParent() return {scaleFactor=1.6} end
  function obj:GetComponent(t) return self.parts[t] end
  function obj:AddComponent(t)
    attempts[t]=(attempts[t] or 0)+1
    if fail[t] then fail[t]=nil return nil end
    local c={}
    if t=="Rect" then c=tr c.anchoredPosition={x=0,y=0} end
    if t=="Button" then c.onClick=event() end
    if t=="Trigger" then
      c.triggers={
        Count=0,
        Clear=function(self)
          for i=1,self.Count do self[i]=nil end
          self.Count=0
        end,
        Add=function(self,e)
          self.Count=self.Count+1
          self[self.Count]=e
        end
      }
    end
    if t=="LateTicker" then
      function c:SetLateTickCallback(cb,owner) self.cb,self.owner=cb,owner end
      function c:ClearLateTickCallback() self.cb=nil end
    end
    self.parts[t]=c
    return c
  end
  return obj
end

local function reset()
  _G.Q_EQUIP_STATE=nil
  _G.TEST_REBOUND=nil
  prefs,fail,attempts,saves,nextId={}, {}, {}, 0, 0
  panel=object("PanelContent")
  panel:AddComponent("Rect")
  backpack=object("EquipBackpack")
  backpack.transform:SetParent(panel.transform)
  equip=object("EquipList")
  equip.transform:SetParent(backpack.transform)
  consumables=object("ConsumableList")
  consumables.transform:SetParent(backpack.transform)
end

local T={Entry=function() return {callback=event()} end}
function typeof(t) return t==T and "Trigger" or t end
local mockCS={UnityEngine={
  GameObject=setmetatable({Find=function() return panel end},{__call=function(_,name) return object(name) end}),
  Canvas="Canvas",
  RectTransform="Rect",
  UI={Button="Button",Image="Image",ScrollRect="ScrollRect"},
  EventSystems={EventTrigger=T,EventTriggerType={BeginDrag=1,Drag=2,EndDrag=3,PointerClick=4},
                PointerEventData={InputButton={Left=0,Right=1}}},
  Vector2=function(x,y) return {x=x,y=y} end,
  Vector3=function(x,y,z) return {x=x,y=y,z=z} end,
  Color=function(...) return {...} end,
  Quaternion={Euler=function(_,_,z) return z end},
  Object={Destroy=function(go)
    local parent=go.transform.parent
    if parent~=nil and parent.children[go.name]==go.transform then parent.children[go.name]=nil end
    go:SetActive(false)
  end},
  PlayerPrefs={
    GetFloat=function(k,d) return prefs[k] or d end,
    SetFloat=function(k,v) prefs[k]=v end,
    Save=function() saves=saves+1 end
  }
}}

mockCS.RPG={
  Client={MonoPerformanceUITransfer="LateTicker",
          GlobalVars={s_UIManager={GetPageByName=function() return nil end}}},
  GameCore={GridFightEquipCategory={Basic=1,Craftable=2},
            GridFightAddItemSourceType={TraitEffectElation=20,TraitEffectElationLaughPoint=21}},
}

local function tick(rev,body)
  return assert(load(("local __equipbar_revision = %d\n"):format(rev)..(body or source),"=EquipBarScript"))()
end
local noViewport="badge preview: waiting for stable bindings"
local function firstLine(v) return (tostring(v):match("^([^\n]*)") or "") end
local function button() return assert(panel.transform:Find("EquipToggleBtn2")).gameObject end
local function triggerEvent(eventId)
  local tr=button():GetComponent("Trigger").triggers
  assert(tr.Count==4)
  for i=1,tr.Count do
    if tr[i].eventID==eventId then return tr[i].callback end
  end
  error("missing trigger: "..eventId)
end
local function trigger(eventId,d) triggerEvent(eventId):Fire(d) end
local function click(which) trigger(4,{button=which}) end
local function lit(name)
  return button().transform:Find(name).gameObject:GetComponent("Image").color[1]==1
end

CS=nil
assert(tick(0)=="wait unity")
G={CS={},NotifyManager={}}
CS={}
assert(tick(0)=="wait unity")
G=nil
CS=mockCS
assert(tick(0)=="wait notify")
G={CS={},NotifyManager={}}
print("PASS: waits for the C# bridge before looking for Unity UI")

reset()
G={CS={NotifyGroup={UI=1},NotifyType={GridFightUpdateEvent=100,GridFightUpdateDone=101}},
  NotifyManager={
    add_notify_handler=function() end,
    remove_notify_handler=function() end,
  }}
assert(firstLine(tick(1))==noViewport)
local firstCallback=triggerEvent(4).callbacks[1]
click(0)
assert(backpack.activeSelf and not equip.activeSelf and consumables.activeSelf)
assert(not lit("BarEquip") and lit("BarCons"))
click(1)
assert(backpack.activeSelf and not equip.activeSelf and not consumables.activeSelf)
assert(not lit("BarEquip") and not lit("BarCons"))
button().transform.anchoredPosition={x=-411,y=-91}
assert(firstLine(tick(1))==noViewport and triggerEvent(4).callbacks[1]==firstCallback)
local edited,n=source:gsub("local function toggle%(d%)","local function toggle(d) _G.TEST_REBOUND=true",1)
assert(n==1)
local oldButton=button():AddComponent("Button")
oldButton.onClick:AddListener(function() error("obsolete callback") end)
local oldArrow=object("Arrow")
oldArrow.transform:SetParent(button().transform)
assert(firstLine(tick(2,edited))==noViewport)
assert(backpack.activeSelf and not equip.activeSelf and not consumables.activeSelf)
assert(not lit("BarEquip") and not lit("BarCons"))
assert(button().transform.anchoredPosition.x==-411 and button().transform.anchoredPosition.y==-91)
assert(not oldButton.enabled and #oldButton.onClick.callbacks==0 and not oldArrow.activeSelf)
assert(#triggerEvent(4).callbacks==1 and triggerEvent(4).callbacks[1]~=firstCallback)
click(0)
assert(_G.TEST_REBOUND and equip.activeSelf and not consumables.activeSelf and lit("BarEquip"))
print("PASS: hot reload rebinds once, preserving independent folds, indicators and live position")

click(0)
button():SetActive(false)
assert(firstLine(tick(2,edited))==noViewport and button().activeSelf)
assert(backpack.activeSelf and not equip.activeSelf and not consumables.activeSelf)
assert(not lit("BarEquip") and not lit("BarCons"))
button().parts.Trigger=nil
assert(firstLine(tick(2,edited))==noViewport and #triggerEvent(4).callbacks==1)
local oldEquip=equip
backpack.transform.children.EquipList=nil
equip=object("EquipList")
equip.transform:SetParent(backpack.transform)
click(0)
assert(equip.activeSelf and not oldEquip.activeSelf)
assert(firstLine(tick(2,edited))==noViewport and lit("BarEquip")==equip.activeSelf)
equip:SetActive(false)
assert(firstLine(tick(2,edited))==noViewport and not lit("BarEquip"))
print("PASS: the same revision repairs and rebinds on replaced lists, without changing original state")

reset()
fail.Trigger=true
assert(tick(3):match("^partial: ") and not button().activeSelf)
assert(firstLine(tick(3))==noViewport and attempts.Trigger==2 and button().activeSelf)
assert(#triggerEvent(4).callbacks==1)
print("PASS: one-shot component failure retries, without a duplicate button")

reset()
assert(firstLine(tick(4))==noViewport)
local d={button=0,pointerId=-1,eligibleForClick=true,delta={x=0,y=10}}
local bound=triggerEvent(4).callbacks[1]
trigger(1,d)
trigger(2,d)
assert(button().transform.anchoredPosition.y==-22 and not d.eligibleForClick)
d.delta={x=-24,y=-48}
trigger(2,d)
local live=button().transform.anchoredPosition
assert(live.y==-52 and tick(4)=="ready" and tick(5)=="ready")
assert(triggerEvent(4).callbacks[1]==bound and button().transform.anchoredPosition==live)
local wrong={button=0,pointerId=-2,delta={x=20,y=20}}
trigger(2,wrong)
trigger(3,wrong)
assert(saves==0 and button().transform.anchoredPosition==live)
-- Unity sends Click before EndDrag iff this pointer is still eligible.
if d.eligibleForClick then click(0) end
trigger(3,d)
assert(backpack.activeSelf and equip.activeSelf and consumables.activeSelf)
assert(saves==1 and prefs.EquipBtnY==-52)
assert(firstLine(tick(5))==noViewport and triggerEvent(4).callbacks[1]~=bound)
assert(button().transform.anchoredPosition.y==-52)
local right={button=1,pointerId=-2,eligibleForClick=true,delta={x=20,y=-20}}
trigger(1,right)
trigger(2,right)
trigger(3,right)
assert(right.eligibleForClick and saves==1 and button().transform.anchoredPosition.y==-52)
click(1)
assert(equip.activeSelf and not consumables.activeSelf)
click(0)
assert(not equip.activeSelf and not consumables.activeSelf and backpack.activeSelf)
-- A missed EndDrag must not block the next real click.
trigger(1,d)
trigger(4,{button=0,eligibleForClick=false})
assert(not equip.activeSelf)
trigger(4,{button=0,eligibleForClick=true})
assert(equip.activeSelf and _G.Q_EQUIP_STATE.dragPointer==nil)

-- Continue the fifth group through the complete deployed entry, its stock
-- bindings, notification callbacks, and the same late ticker used in-game.
local function material(id,config,raw,fmt)
  local m={
    UniqueID=id,ItemID=config,SourceType=0,EquippedUniqueID=0,
    IsTemporary=false,IsDressed=false,HasOwner=false,IsDisplaySpecialParam=false,
    FrameInfo={Rank=1,HasTraitFrame=false},CanSell=true,SellPrice=3,
    ExtraDescList={Count=0},spriteName="same-image",
    EquipItemConfig={ItemConfig={ItemID=config},
      CategoryInfoConfig={EquipCategory=1,CanBeUsedAsCraftCost=true}},
  }
  function m:GetDisplayPropertyList()
    return {Count=1,[0]={PropertyType=9,Value=raw,FormatValue=fmt or "10%"}}
  end
  return m
end

local function fixture()
  reset()
  local notes={[100]=event(),[101]=event()}
  G={CS={NotifyGroup={UI=1},NotifyType={GridFightUpdateEvent=100,GridFightUpdateDone=101}},
    NotifyManager={
      add_notify_handler=function(group,kind,cb,owner)
        assert(group==1 and type(owner)=="table")
        notes[kind]:AddListener(cb)
      end,
      remove_notify_handler=function(group,kind,cb,owner)
        assert(group==1 and type(owner)=="table")
        notes[kind]:RemoveListener(cb)
      end,
    }}
  local scroll=object("ScrollView")
  scroll.transform:SetParent(equip.transform)
  scroll.parts.ScrollRect={onValueChanged=event()}
  local v=object("Viewport")
  v.transform:SetParent(scroll.transform)
  local content=object("Content")
  content.transform:SetParent(v.transform)
  content:AddComponent("Rect")
  mockCS.UnityEngine.UI.LayoutRebuilder={ForceRebuildLayoutImmediate=function(r)
    assert(r==content.transform)
  end}
  local fx={notes=notes,scroll=scroll,viewport=v,pack={_equip_items={}},slots={},virtual={}}
  local pack=fx.pack
  function pack:get_root_transform() return equip.transform end
  function pack:get_slot_panel_by_index(i)
    if not fx.virtual[i] then return fx.slots[i] end
  end
  local drag={is_dragging=function() return fx.dragging==true end}
  function pack:_get_drag_panel() return drag end
  local ui={GetPageByName=function(_,name)
    assert(name=="GridFightPreparationPage")
    return {LuaTable={_binder={panel_equip_item_pack=pack}}}
  end}
  mockCS.RPG={
    Client={MonoPerformanceUITransfer="LateTicker",GlobalVars={s_UIManager=ui}},
    GameCore={GridFightEquipCategory={Basic=1,Craftable=2},GridFightAddItemSourceType={TraitEffectElation=20,TraitEffectElationLaughPoint=21}},
  }
  local stockMethods={}
  function stockMethods:setup_view(item)
    if self.expectRestored then assert(self.go.activeSelf,"plugin must restore before stock setup_view runs") end
    self.bound=item
    self.stockCalls=(self.stockCalls or 0)+1
    return "stock result",nil,9
  end
  local function add(i,m)
    local slotObj=object("Slot"..i)
    slotObj.transform:SetParent(content.transform)
    local slotRect=slotObj:AddComponent("Rect")
    slotRect.rect.xMax,slotRect.testY=100+i*100,200
    local icon=object("Icon")
    icon.transform:SetParent(slotObj.transform)
    local r=icon:AddComponent("Rect")
    r.rect.xMax,r.testY=100+i*100,200
    local slotPanel=setmetatable({go=slotObj,icon=icon,bound=m},{__index=stockMethods})
    local itemPanel={
      get_equip_item=function() return slotPanel.bound end,
      get_root_transform=function() return icon.transform end,
    }
    function slotPanel:get_equip_uid() return self.bound.UniqueID end
    function slotPanel:get_equip_item_panel() return itemPanel end
    function slotPanel:get_root_transform() return self.go.transform end
    fx.slots[i],pack._equip_items[i]=slotPanel,m
  end
  add(1,material(10,5,0.10001))
  add(2,material(11,5,0.10001))
  add(3,material(12,5,0.10001))
  add(4,material(13,5,0.10001)) -- 池子里复用出来的隐藏格：和前三格同一种装备
  fx.slots[4].go:SetActive(false) -- Hidden by the game's own UI, not by the plugin.
  local function findAny(name)
    for _,root in ipairs({panel.transform,backpack.transform,equip.transform,v.transform,content.transform}) do
      local tr=root:Find(name)
      if tr~=nil then return tr end
    end
    return nil
  end
  function fx:ticker()
    return assert(findAny("WDHO_StackBadgeTicker")).gameObject:GetComponent("LateTicker")
  end
  function fx:layer()
    return assert(findAny("WDHO_StackBadgeLayer")).gameObject
  end
  -- What the game does on a long press: it activates its own upgrade / privilege
  -- preview inside the equipment tree, without adding an _equip_items row.
  function fx:addPreview()
    local node=object("UpgradePreview")
    node.transform:SetParent(equip.transform)
    node:AddComponent("Rect")
    return node
  end
  function fx:step()
    local ticker=self:ticker()
    -- Keep interested in the observable state, not an implementation's frame cadence.
    for _=1,12 do ticker.cb(ticker.owner,0.016) end
  end
  function fx:visible()
    local n=0
    for i=1,3 do
      if not self.virtual[i] and self.slots[i].go.activeSelf then n=n+1 end
    end
    return n
  end
  function fx:assertNativeHidden()
    assert(not self.slots[4].go.activeSelf,"plugin must not activate unrelated stock-hidden slot")
  end
  return fx
end

-- 旧版徽标运行时（setup_view 包装、拖动中展开第二格、逐格恢复表）已被现版本取代：
-- 现在每拍 restoreLast + ticker 回调重算分组。下面是一组与现实现一致的冒烟用例。
local fx=fixture()
assert(tick(5):match("^badge preview:"))
fx:step()
assert(fx:layer().activeSelf,"badge layer is created for a stack")
assert(fx:visible()==1,"idle: a group of equivalents collapses to one visible slot")

fx.dragging=true
fx:step()
assert(fx:visible()==1,"stock drag active: slots are not touched")
fx.dragging=false
fx:step()
assert(fx:visible()==1 and fx:layer().activeSelf,"drop: collapsed again")

local oldTicker=fx:ticker()
panel=nil
assert(tick(6)=="idle")
assert(oldTicker.cb==nil,"dispose: late ticker callback removed")
assert(#fx.notes[100].callbacks==0 and #fx.notes[101].callbacks==0,"dispose: notify handlers removed")
assert(#fx.scroll.parts.ScrollRect.onValueChanged.callbacks==0,"dispose: scroll listener removed")
assert(fx:visible()==3,"dispose: every slot the plugin folded is visible again")
print("PASS: badge runtime mounts, folds, ignores stock drags and cleans up on dispose")
