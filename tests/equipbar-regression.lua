-- Offline regression: lua tests/equipbar-regression.lua
-- Loads the production chunk with the same revision prefix as the native worker.
local file=assert(io.open("lua/EquipBarScript.lua","rb"))
local source=file:read("*a")
file:close()

local panel,backpack,prefs,fail,attempts,saves,nextId
local function event()
  return {
    callbacks={},
    AddListener=function(self,cb) table.insert(self.callbacks,cb) end,
    RemoveAllListeners=function(self) self.callbacks={} end,
    Fire=function(self,...) for _,cb in ipairs(self.callbacks) do cb(...) end end
  }
end

local function object(name)
  nextId=nextId+1
  local obj={name=name,id=nextId,activeSelf=true,parts={}}
  local tr={gameObject=obj,children={},rect={width=1200,height=800}}
  obj.transform=tr
  function tr:Find(n) return self.children[n] end
  function tr:SetParent(parent)
    assert(parent.children[name]==nil,"duplicate child: "..name)
    parent.children[name]=self
  end
  function tr:SetAsLastSibling() end
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
end

local T={Entry=function() return {callback=event()} end}
function typeof(t) return t==T and "Trigger" or t end
local mockCS={UnityEngine={
  GameObject=setmetatable({Find=function() return panel end},{__call=function(_,name) return object(name) end}),
  Canvas="Canvas",
  RectTransform="Rect",
  UI={Button="Button",Image="Image"},
  EventSystems={EventTrigger=T,EventTriggerType={BeginDrag=1,Drag=2,EndDrag=3},
                PointerEventData={InputButton={Left=0,Right=1}}},
  Vector2=function(x,y) return {x=x,y=y} end,
  Color=function(...) return {...} end,
  Quaternion={Euler=function(_,_,z) return z end},
  PlayerPrefs={
    GetFloat=function(k,d) return prefs[k] or d end,
    SetFloat=function(k,v) prefs[k]=v end,
    Save=function() saves=saves+1 end
  }
}}

local function tick(rev,body)
  return assert(load(("local __equipbar_revision = %d\n"):format(rev)..(body or source),"=EquipBarScript"))()
end
local function button() return assert(panel.transform:Find("EquipToggleBtn2")).gameObject end
local function clickEvent() return button():GetComponent("Button").onClick end
local function arrow() return button().transform:Find("Arrow") end
local function trigger(eventId,d)
  local tr=button():GetComponent("Trigger").triggers
  assert(tr.Count==3)
  for i=1,tr.Count do
    if tr[i].eventID==eventId then tr[i].callback:Fire(d) return end
  end
  error("missing trigger: "..eventId)
end

CS=nil
assert(tick(0)=="wait unity")
CS={}
assert(tick(0)=="wait unity")
CS=mockCS
print("PASS: waits for the C# bridge before looking for Unity UI")

reset()
assert(tick(1)=="ready")
local firstCallback=clickEvent().callbacks[1]
clickEvent():Fire()
assert(not backpack.activeSelf and arrow().localRotation==180)
button().transform.anchoredPosition={x=-411,y=-91}
assert(tick(1)=="ready" and clickEvent().callbacks[1]==firstCallback)
local edited,n=source:gsub("local function toggle%(%)","local function toggle() _G.TEST_REBOUND=true",1)
assert(n==1)
assert(tick(2,edited)=="ready")
assert(not backpack.activeSelf and arrow().localRotation==180)
assert(button().transform.anchoredPosition.x==-411 and button().transform.anchoredPosition.y==-91)
assert(#clickEvent().callbacks==1 and clickEvent().callbacks[1]~=firstCallback)
clickEvent():Fire()
assert(_G.TEST_REBOUND and backpack.activeSelf and arrow().localRotation==0)
print("PASS: hot reload rebinds once, preserving fold, arrow and live position")

clickEvent():Fire()
button():SetActive(false)
assert(tick(2,edited)=="ready" and button().activeSelf)
assert(not backpack.activeSelf and arrow().localRotation==180)
button().parts.Button=nil
assert(tick(2,edited)=="ready" and #clickEvent().callbacks==1)
print("PASS: same revision repairs disabled or incomplete button without opening backpack")

reset()
fail.Button=true
assert(tick(3):match("^partial: ") and not button().activeSelf)
assert(tick(3)=="ready" and attempts.Button==2 and button().activeSelf)
assert(#clickEvent().callbacks==1)
print("PASS: one-shot component failure retries, without a duplicate button")

reset()
assert(tick(4)=="ready")
local d={button=0,eligibleForClick=true,delta={x=0,y=10}}
trigger(1,d)
trigger(2,d)
assert(button().transform.anchoredPosition.y==-22 and not d.eligibleForClick)
-- Unity sends Click before EndDrag iff this pointer is still eligible.
if d.eligibleForClick then clickEvent():Fire() end
trigger(3,d)
assert(backpack.activeSelf and saves==1 and prefs.EquipBtnY==-22)
local right={button=1,eligibleForClick=true,delta={x=20,y=-20}}
trigger(1,right)
trigger(2,right)
trigger(3,right)
assert(right.eligibleForClick and saves==1 and button().transform.anchoredPosition.y==-22)
clickEvent():Fire()
assert(not backpack.activeSelf and arrow().localRotation==180)
print("PASS: clamped drag never clicks; regular click still toggles")
