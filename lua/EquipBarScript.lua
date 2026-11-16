local bridge=CS
if bridge==nil then return "wait unity" end
local U=bridge.UnityEngine
if U==nil then return "wait unity" end
local PC="UIRoot/Page/GridFightS2TeamEditPage(Clone)/Root/PanelContent"
local pc=U.GameObject.Find(PC)
if pc==nil then return "idle" end
local id=pc:GetInstanceID()
local revision=__equipbar_revision or 0

local bpTr=pc.transform:Find("EquipBackpack")
if bpTr==nil then return "wait bp" end
local bp=bpTr.gameObject
local btnTr=pc.transform:Find("EquipToggleBtn2")
local btn=btnTr and btnTr.gameObject
local R=typeof(U.RectTransform)
local B=typeof(U.UI.Button)
local T=typeof(U.EventSystems.EventTrigger)
local state=_G.Q_EQUIP_STATE
if state==nil or state.panel~=id then
  state={panel=id}
  _G.Q_EQUIP_STATE=state
end

-- 发布号只在完整绑定后提交；按钮被删除、禁用或缺少组件时仍走重建。
if state.revision==revision and btn~=nil and btn.activeSelf
    and state.button==btn:GetInstanceID() and state.backpack==bp:GetInstanceID()
    and btn:GetComponent(R)~=nil and btn:GetComponent(B)~=nil and btn:GetComponent(T)~=nil then
  return "ready"
end

local function child(parent,name)
  local tr=parent:Find(name)
  if tr~=nil then return tr.gameObject end
  local obj=U.GameObject(name)
  obj.transform:SetParent(parent,false)
  return obj
end

local function component(obj,kind,label)
  local value=obj:GetComponent(kind)
  if value==nil then
    obj:AddComponent(kind)
    value=obj:GetComponent(kind)
  end
  if value==nil then error(label.." missing") end
  return value
end

local function geometry(r,anchor,w,h)
  r.anchorMin=anchor
  r.anchorMax=anchor
  r.pivot=U.Vector2(0.5,0.5)
  r.sizeDelta=U.Vector2(w,h)
end

state.revision=nil
local ok,err=pcall(function()
  btn=btn or child(pc.transform,"EquipToggleBtn2")
  btn:SetActive(false)
  local buttonId=btn:GetInstanceID()
  local backpackId=bp:GetInstanceID()
  local panelRect=pc:GetComponent(R)
  local canvas=pc:GetComponentInParent(typeof(U.Canvas))
  if panelRect==nil or panelRect.rect.width<44 or panelRect.rect.height<44 then error("invalid panel rect") end
  if canvas==nil or canvas.scaleFactor<=0 then error("invalid canvas scale") end

  local function clampPos(x,y)
    -- 右上锚点、中间 pivot：限制按钮整个 44x44 都在面板内。
    local rect=panelRect.rect
    local mx=math.max(22,rect.width-22)
    local my=math.max(22,rect.height-22)
    return math.max(-mx,math.min(-22,x)),math.max(-my,math.min(-22,y))
  end

  local center=U.Vector2(0.5,0.5)
  local I=typeof(U.UI.Image)
  local r=component(btn,R,"button rect")
  local x,y
  if state.positioned==buttonId then
    local p=r.anchoredPosition
    x,y=p.x,p.y
  else
    x=U.PlayerPrefs.GetFloat("EquipBtnX",-300)
    y=U.PlayerPrefs.GetFloat("EquipBtnY",-18)
  end
  if x~=x or y~=y then x,y=-300,-18 end
  x,y=clampPos(x,y)
  geometry(r,U.Vector2(1,1),44,44)
  r.anchoredPosition=U.Vector2(x,y)
  state.positioned=buttonId
  component(btn,I,"button image").color=U.Color(1,1,1,0.75)
  local bc=component(btn,B,"button")

  local inner=child(btn.transform,"EquipToggleInner")
  geometry(component(inner,R,"inner rect"),center,34,34)
  component(inner,I,"inner image").color=U.Color(0,0,0,0.95)

  local arrow=child(btn.transform,"Arrow")
  local ar=component(arrow,R,"arrow rect")
  geometry(ar,center,24,24)
  local function arm(name,y,angle)
    local a=child(arrow.transform,name)
    local aRect=component(a,R,"arm rect")
    geometry(aRect,center,14,3)
    aRect.anchoredPosition=U.Vector2(-3,y)
    aRect.localRotation=U.Quaternion.Euler(0,0,angle)
    component(a,I,"arm image").color=U.Color(1,1,1,1)
  end
  arm("Arm1",4.5,40)
  arm("Arm2",-4.5,-40)
  arrow.transform:SetAsLastSibling()

  -- 只在当前背包首次初始化时校正旧布局；重绑不改背包显隐。
  if state.layout~=backpackId then
    local ct=bp.transform:Find("EquipList/ScrollView/Viewport/Content")
    if ct~=nil then
      local cr=ct.gameObject:GetComponent(R)
      if cr~=nil then
        local corner=U.Vector2(1,1)
        cr.anchorMin=corner
        cr.anchorMax=corner
        cr.pivot=corner
        cr.anchoredPosition=U.Vector2(0,0)
        pcall(function() U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(cr) end)
      end
    end
    state.layout=backpackId
  end

  local function syncArrow(b)
    ar.localRotation=U.Quaternion.Euler(0,0,b.activeSelf and 0 or 180)
  end
  local function toggle()
    local tr=pc.transform:Find("EquipBackpack")
    if tr==nil then return end
    local b=tr.gameObject
    b:SetActive(not b.activeSelf)
    syncArrow(b)
  end

  local E=U.EventSystems
  local left=E.PointerEventData.InputButton.Left
  local function beginDrag(d)
    -- Unity 已判定为拖动，直接取消该指针的 click；不能用被钳制后的位移判定。
    if d.button==left then d.eligibleForClick=false end
  end
  local function drag(d)
    if d.button~=left then return end
    local p=r.anchoredPosition
    local scale=canvas.scaleFactor
    if scale<=0 then return end
    local nx,ny=clampPos(p.x+d.delta.x/scale,p.y+d.delta.y/scale)
    r.anchoredPosition=U.Vector2(nx,ny)
  end
  local function endDrag(d)
    if d.button~=left then return end
    local p=r.anchoredPosition
    local nx,ny=clampPos(p.x,p.y)
    if nx~=p.x or ny~=p.y then r.anchoredPosition=U.Vector2(nx,ny) end
    U.PlayerPrefs.SetFloat("EquipBtnX",nx)
    U.PlayerPrefs.SetFloat("EquipBtnY",ny)
    U.PlayerPrefs.Save()
  end

  local tg=component(btn,T,"event trigger")
  tg.triggers:Clear()
  local function bind(eventId,callback)
    local entry=E.EventTrigger.Entry()
    entry.eventID=eventId
    entry.callback:AddListener(callback)
    tg.triggers:Add(entry)
  end
  local ids=E.EventTriggerType
  bind(ids.BeginDrag,beginDrag)
  bind(ids.Drag,drag)
  bind(ids.EndDrag,endDrag)
  if tg.triggers.Count~=3 then error("incomplete drag listeners") end
  bc.onClick:RemoveAllListeners()
  bc.onClick:AddListener(toggle)
  syncArrow(bp)
  btn:SetActive(true)
  if not btn.activeSelf then error("button activation failed") end
  state.button,state.backpack,state.revision=buttonId,backpackId,revision
end)
if not ok then return "partial: "..tostring(err) end
return "ready"
