local EquipBinding=(function()
-- Read the current backpack model and verify the visible slot's native binding.
local M={}

local function uid(value)
  if type(value)=="string" and value:match("^[1-9]%d*$") then return value end
  if type(value)=="number" and value>=1 and value<=9007199254740991 and value%1==0 then
    return string.format("%.0f",value)
  end
  error("unsupported equipment UID")
end

function M.read(bridge,equipTr,requireDragState)
  local client=bridge.RPG.Client
  local page=client.GlobalVars.s_UIManager:GetPageByName("GridFightPreparationPage")
  local pageData=page and page.LuaTable
  if pageData==nil then return nil,"waiting for preparation page" end
  local binder=pageData._binder
  local pack=binder and binder.panel_equip_item_pack
  if pack==nil then return nil,"waiting for equipment panel" end
  local root=pack:get_root_transform()
  if root==nil or root.gameObject:GetInstanceID()~=equipTr.gameObject:GetInstanceID() then
    return nil,"equipment panel changed"
  end
  local dragging=false
  if requireDragState then
    local drag=pack:_get_drag_panel()
    if drag==nil then return nil,"drag state unavailable" end
    dragging=drag:is_dragging()
    if type(dragging)~="boolean" then return nil,"drag state unavailable" end
  end

  local data=pack._equip_items
  if type(data)~="table" then return nil,"waiting for equipment data" end
  local rows,seen={},{}
  local n=#data
  for i in pairs(data) do
    if type(i)~="number" or i%1~=0 or i<1 or i>n then return nil,"invalid equipment list" end
  end
  for i=1,n do
    local item=data[i]
    if item==nil then return nil,"invalid equipment list" end
    local nativeId=item.UniqueID
    local id=uid(nativeId)
    if seen[id] then return nil,"duplicate equipment UID" end
    seen[id]=true
    local row={itemId=id,item=item,nativeId=nativeId}
    local slot=pack:get_slot_panel_by_index(i)
    if slot~=nil then
      local panel=slot:get_equip_item_panel()
      local bound=panel and panel:get_equip_item()
      if bound==nil or slot:get_equip_uid()~=nativeId
          or bound.UniqueID~=nativeId or not rawequal(bound,item) then
        return nil,"slot rebinding"
      end
      row.transform=panel:get_root_transform()
      if row.transform==nil or not row.transform:IsChildOf(equipTr) then
        return nil,"slot moved"
      end
      row.slot=slot
    end
    rows[i]=row
  end
  return rows,nil,dragging
end

function M.report(bridge,equipTr)
  local ok,rows,reason=pcall(M.read,bridge,equipTr)
  if not ok then
    if type(rows)=="string" and rows:find("unsupported equipment UID",1,true) then
      return "binding preview: unsupported equipment UID representation"
    end
    return "binding preview: bridge read failed"
  end
  if rows==nil then return "binding preview: "..reason end
  local visible,base=0,{}
  for _,row in ipairs(rows) do
    if row.transform~=nil then visible=visible+1 end
    local got,itemId=pcall(function() return row.item.EquipItemConfig.ItemConfig.ItemID end)
    if got and type(itemId)=="number" then base[itemId]=(base[itemId] or 0)+1 end
  end
  local repeated=0
  for _,count in pairs(base) do if count>1 then repeated=repeated+1 end end
  -- Report number of repeated configurations, not individual equipment/account data.
  return string.format("binding preview: backpack=%d visible=%d same-config=%d; equality not certified",
    #rows,visible,repeated)
end

return M

end)()
local EquipEquivalence=(function()
-- The first supported class is ordinary, undressed crafting materials.
-- Compare native values, not sprite names, formatted tooltip text, or object addresses.
local M={}

local function finite(v)
  return type(v)=="number" and v>-math.huge and v<math.huge
end

local function integer(v)
  return finite(v) and v%1==0
end

local function atom(v)
  return finite(v) or type(v)=="userdata"
end

local function read(game,item)
  local cfg=item.EquipItemConfig
  local category=cfg.CategoryInfoConfig
  local material=game.GridFightEquipCategory.Basic
  if material==nil or category.EquipCategory~=material
      or category.CanBeUsedAsCraftCost~=true then return nil,"not-basic" end
  local id=item.ItemID
  if not integer(id) or id<=0 or id~=cfg.ItemConfig.ItemID then return nil,"config" end
  local source=item.SourceType
  local elation=game.GridFightAddItemSourceType
  if not atom(source) or elation.TraitEffectElation==nil or elation.TraitEffectElationLaughPoint==nil then
    return nil,"source"
  end
  if source==elation.TraitEffectElation or source==elation.TraitEffectElationLaughPoint
      or item.IsTemporary~=false or item.IsDisplaySpecialParam~=false
      or item.IsDressed~=false or item.HasOwner~=false or item.EquippedUniqueID~=0 then
    return nil,"variant"
  end
  local extra=item.ExtraDescList
  if (extra~=nil and extra.Count~=0) or (cfg.ElationDesc~=nil and cfg.ElationDesc~="") then
    return nil,"extra-effect"
  end
  local frame=item.FrameInfo
  if frame==nil or frame.HasTraitFrame~=false or not atom(frame.Rank) then return nil,"frame" end
  local sell,price=item.CanSell,item.SellPrice
  if type(sell)~="boolean" or not integer(price) then return nil,"sale" end

  local listOk,properties=pcall(function() return item:GetDisplayPropertyList() end)
  if not listOk or properties==nil or not integer(properties.Count) or properties.Count<=0 then return nil,"properties" end
  local raw={}
  for i=0,properties.Count-1 do
    local prop=properties[i]
    if prop==nil then return nil,"property-type" end
    local fieldOk,kind,value=pcall(function() return prop.PropertyType,prop.Value end)
    if not fieldOk or not atom(kind) then return nil,"property-type" end
    if type(value)=="userdata" then
      -- Native Lua compares this FixPoint value with FixPoint.Zero using '<'.
      -- If the adapter does not expose that comparison, fail closed.
      local zero=game.FixPoint.Zero
      if type(zero)~="userdata" or getmetatable(value)~=getmetatable(zero) then return nil,"property-value" end
      local lt,gt=value<zero,zero<value
      if lt and gt then return nil,"property-value" end
    elseif not finite(value) then
      return nil,"property-value"
    end
    raw[#raw+1]={kind,value}
  end
  return {id=id,source=source,rank=frame.Rank,sell=sell,price=price,raw=raw}
end

local function equal(a,b)
  if a.source~=b.source or a.rank~=b.rank or a.sell~=b.sell or a.price~=b.price or #a.raw~=#b.raw then return false end
  for i,v in ipairs(a.raw) do
    local other=b.raw[i]
    if v[1]~=other[1] or type(v[2])~=type(other[2]) then return false end
    -- Less-than in both directions preserves fixed-point precision; no conversion.
    if v[2]<other[2] or other[2]<v[2] then return false end
  end
  return true
end

function M.classify(bridge,rows)
  local result,byConfig,excluded={},{},{}
  local game=bridge.RPG.GameCore
  local classes=0
  for i,row in ipairs(rows) do
    local ok,profile,why=pcall(read,game,row.item)
    if not ok then why="unreadable" end
    if not ok or profile==nil then
      excluded[why]=(excluded[why] or 0)+1
      -- A distinct non-shared key makes an unknown row ineligible for any badge.
      result[i]="excluded:"..row.itemId
    else
      local peers=byConfig[profile.id]
      if peers==nil then peers={} byConfig[profile.id]=peers end
      local key
      for _,peer in ipairs(peers) do
        local compared,match=pcall(equal,profile,peer.profile)
        if compared and match then key=peer.key break end
      end
      if key==nil then
        classes=classes+1
        key="material:"..classes
        peers[#peers+1]={profile=profile,key=key}
      end
      result[i]=key
    end
  end
  return result,excluded
end

return M

end)()
local StackBadgeLayer=(function()
-- Owned viewport overlay. The caller must supply a complete inventory snapshot from
-- the real item binding, and invalidate it before slot reuse, drag or page changes.
-- Rows: { itemId = string, groupKey = string, anchor = {x=0..1,y=0..1} | nil }.
-- groupKey must include every property that defines equality. A sprite name is not enough.
local M={}

local glyphs={["0"]="abcdef",["1"]="bc",["2"]="abdeg",["3"]="abcdg",
              ["4"]="bcfg",["5"]="acdfg",["6"]="acdefg",["7"]="abc",
              ["8"]="abcdefg",["9"]="abcdfg"}
local segments={
  {"a",0,5,4,1}, {"b",2,2.5,1,4}, {"c",2,-2.5,1,4},
  {"d",0,-5,4,1},{"e",-2,-2.5,1,4},{"f",-2,2.5,1,4},{"g",0,0,4,1}
}

local function unit(v)
  return type(v)=="number" and v>=0 and v<=1
end

local function project(rows)
  assert(type(rows)=="table","missing complete item snapshot")
  local seen,byKey,groups={},{},{}
  local n=#rows
  for k in pairs(rows) do
    assert(type(k)=="number" and k%1==0 and k>=1 and k<=n,"invalid item snapshot index")
  end
  for i=1,n do
    local row=rows[i]
    assert(type(row)=="table","sparse item snapshot")
    local item,key,anchor=row.itemId,row.groupKey,row.anchor
    assert(type(item)=="string" and item~="" and not seen[item],"invalid or duplicate item identity")
    assert(type(key)=="string" and key~="","missing equipment equivalence key")
    assert(anchor==nil or (type(anchor)=="table" and unit(anchor.x) and unit(anchor.y)),"invalid viewport anchor")
    seen[item]=true
    local group=byKey[key]
    if group==nil then
      group={count=0}
      byKey[key]=group
      groups[#groups+1]=group
    end
    group.count=group.count+1
    if group.anchor==nil and anchor~=nil then group.anchor=anchor end
  end
  return groups
end

function M.new(U,viewport)
  local rectType,imageType=typeof(U.RectTransform),typeof(U.UI.Image)
  local function rect(parent,name)
    local go=U.GameObject(name)
    go:SetActive(false)
    local r=assert(go:AddComponent(rectType),name.." RectTransform missing")
    r:SetParent(parent,false)
    return go,r
  end
  local layer,container=rect(viewport,"WDHO_StackBadgeLayer")
  layer.transform:SetAsLastSibling()
  local v=U.Vector2
  container.anchorMin,container.anchorMax=v(0,0),v(1,1)
  container.offsetMin,container.offsetMax=v(0,0),v(0,0)
  local pool={}
  local pending=nil
  local disposed=false

  local function image(parent,name,color)
    local go,r=rect(parent,name)
    local im=assert(go:AddComponent(imageType),name.." Image missing")
    im.color=color
    im.raycastTarget=false
    return go,r
  end

  local white=U.Color(1,1,1,1)
  local center=v(0.5,0.5)
  local function place(r,x,y,w,h)
    r.anchorMin,r.anchorMax,r.pivot=center,center,center
    r.sizeDelta,r.anchoredPosition=v(w,h),v(x,y)
  end
  local function getBadge(index)
    if pool[index]~=nil then return pool[index] end
    local go,r=image(container,"Badge"..index,U.Color(0,0,0,0.85))
    local badge={go=go,r=r,digits={}}
    for i=1,2 do
      local stroke,sr=image(r,"Times"..i,white)
      place(sr,0,0,6,1)
      sr.localRotation=U.Quaternion.Euler(0,0,i==1 and 45 or -45)
      stroke:SetActive(true)
      if i==1 then badge.t1=sr else badge.t2=sr end
    end
    pool[index]=badge
    return badge
  end

  local function setBadge(b,at,count)
    local s=tostring(count)
    local width=10+7*#s
    b.r.anchorMin,b.r.anchorMax=v(at.x,at.y),v(at.x,at.y)
    b.r.pivot=v(1,0)
    b.r.sizeDelta,b.r.anchoredPosition=v(width,15),v(-2,2)
    local tx=-width/2+5
    b.t1.anchoredPosition,b.t2.anchoredPosition=v(tx,0),v(tx,0)
    for d=1,#s do
      local digit=b.digits[d]
      if digit==nil then
        local go,r=rect(b.r,"Digit"..d)
        digit={go=go,r=r,parts={}}
        b.digits[d]=digit
        for _,spec in ipairs(segments) do
          local bit,br=image(r,spec[1],white)
          place(br,spec[2],spec[3],spec[4],spec[5])
          digit.parts[spec[1]]=bit
        end
      end
      place(digit.r,-width/2+10+7*(d-0.5),0,7,12)
      local on=assert(glyphs[s:sub(d,d)])
      for segment,bit in pairs(digit.parts) do
        bit:SetActive(on:find(segment,1,true)~=nil)
      end
      digit.go:SetActive(true)
    end
    for d=#s+1,#b.digits do b.digits[d].go:SetActive(false) end
    b.go:SetActive(true)
  end

  local result={}
  function result:invalidate()
    assert(not disposed,"badge layer already disposed")
    layer:SetActive(false)
    pending={}
    return pending
  end
  function result:publish(token,rows)
    if disposed or token==nil or token~=pending then return false,"stale snapshot" end
    pending=nil
    local groups=project(rows)
    local visible=0
    for _,group in ipairs(groups) do
      if group.count>1 and group.anchor~=nil then
        visible=visible+1
        setBadge(getBadge(visible),group.anchor,group.count)
      end
    end
    for i=visible+1,#pool do pool[i].go:SetActive(false) end
    layer:SetActive(visible>0)
    return true,visible
  end
  function result:dispose()
    if disposed then return end
    disposed,pending=true,nil
    layer:SetActive(false)
    U.Object.Destroy(layer)
  end
  return result
end

return M

end)()
local EquipBadgeRuntime=(function()
-- Only collapse verified stock slots. Release visibility before a pooled slot is rebound.
local M={}

local function sameRows(old,rows)
  if old==nil or #old~=#rows then return false end
  for i,row in ipairs(rows) do
    local prev=old[i]
    if row.itemId~=prev.itemId or not rawequal(row.item,prev.item) then return false end
  end
  return true
end

local function samePlacement(old,rows)
  if old==nil or #old~=#rows then return false end
  for i,row in ipairs(rows) do
    local a,b=old[i],row
    if a.itemId~=b.itemId or a.groupKey~=b.groupKey then return false end
    local x,y=a.anchor,b.anchor
    if (x==nil)~=(y==nil) or (x~=nil and (x.x~=y.x or x.y~=y.y)) then return false end
  end
  return true
end

function M.new(bridge,G,equipTr,viewport,binding,equiv,badges)
  local U=bridge.UnityEngine
  local notify=G.NotifyManager
  local group=G.CS.NotifyGroup.UI
  local start,done=G.CS.NotifyType.GridFightUpdateEvent,G.CS.NotifyType.GridFightUpdateDone
  assert(start~=nil and done~=nil and start~=done,"missing stock update events")
  local owner={}
  local ticker,tickerGo,layer,onStart,onDone,scroll,onScroll
  local subscribedStart,subscribedDone=false,false
  local checking,waiting,disposed=false,false,false
  local catalog,keys,placements=nil,nil,nil
  local eligible,exclusions=0,"none"
  local hidden,layoutDirty,epoch={},false,0
  local result={status="badge preview: waiting for stable bindings"}
  local rectType=typeof(U.RectTransform)

  local function hide(reason)
    if placements~=nil then placements=nil layer:invalidate() end
    result.status="badge preview: "..reason
  end

  -- Sample all four corners plus the centre, then intersect with the viewport.  A
  -- slot whose rect is only partly on screen is still visible; testing a single
  -- corner made a slightly offset row report itself as gone.
  local function locate(tr,vr,measureHidden)
    if tr==nil or (not measureHidden and tr.gameObject.activeInHierarchy~=true) then return nil end
    local r=tr.gameObject:GetComponent(rectType)
    if r==nil then return nil end
    local rc=r.rect
    local mx,my=(rc.xMin+rc.xMax)/2,(rc.yMin+rc.yMax)/2
    local minX,maxX,minY,maxY=math.huge,-math.huge,math.huge,-math.huge
    local pts={{rc.xMin,rc.yMin},{rc.xMin,rc.yMax},{rc.xMax,rc.yMin},{rc.xMax,rc.yMax},{mx,my}}
    for k=1,#pts do
      local p=viewport:InverseTransformPoint(r:TransformPoint(U.Vector3(pts[k][1],pts[k][2],0)))
      local nx=(p.x-vr.xMin)/vr.width
      local ny=(p.y-vr.yMin)/vr.height
      if nx<minX then minX=nx end
      if nx>maxX then maxX=nx end
      if ny<minY then minY=ny end
      if ny>maxY then maxY=ny end
    end
    local x0,x1=math.max(minX,0),math.min(maxX,1)
    local y0,y1=math.max(minY,0),math.min(maxY,1)
    if x0>x1 or y0>y1 then return nil end
    return {x=(x0+x1)/2,y=(y0+y1)/2}
  end

  local function content()
    return equipTr:Find("ScrollView/Viewport/Content")
  end
  local function rebuild()
    if not layoutDirty then return end
    layoutDirty=false
    local ct=content()
    local rect=ct and ct.gameObject:GetComponent(rectType)
    if rect~=nil then U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(rect) end
  end
  local function slotOf(tr,cid)
    while tr~=nil do
      local parent=tr.parent
      if parent==nil then return nil end
      if parent.gameObject:GetInstanceID()==cid then return tr end
      tr=parent
    end
  end
  local function isBound(rec)
    local panel=rec.slot:get_equip_item_panel()
    if rec.slot:get_equip_uid()~=rec.uid or panel==nil
        or not rawequal(panel:get_equip_item(),rec.item) then return false end
    local tr=panel:get_root_transform()
    return tr~=nil and tr:IsChildOf(rec.go.transform)
  end
  -- The record must outlive the restore attempt.  Dropping it before SetActive
  -- succeeded left the slot hidden for whatever item was bound next.
  local function release(id)
    local rec=hidden[id]
    if rec==nil then return end
    if rawget(rec.slot,"setup_view")==rec.wrap then
      rawset(rec.slot,"setup_view",rec.ownMethod)
    end
    -- We only ever hid this object, so its visibility must be restored regardless of
    -- which item the slot now claims to hold.  Gating on isBound is what leaked the
    -- hidden state onto the next item after a rebind.
    if rec.go.activeSelf==false then
      layoutDirty=true
      local ok=pcall(function() rec.go:SetActive(true) end)
      if ok and rec.go.activeSelf==true then
        hidden[id]=nil
        return
      end
      -- Keep the record so the next tick retries instead of abandoning a hidden object.
      rec.restoreTries=(rec.restoreTries or 0)+1
      if rec.restoreTries>120 then hidden[id]=nil end
      return
    end
    hidden[id]=nil
  end
  local function discard(reason)
    epoch=epoch+1
    catalog,keys=nil,nil
    pcall(hide,reason)
    for id in pairs(hidden) do pcall(release,id) end
  end
  -- Returns false when this slot cannot be observed.  The caller expands only that
  -- stack; a slot we cannot watch must never take the whole page down with it.
  local function conceal(rec)
    if hidden[rec.id]~=nil or rec.go.activeSelf~=true or not isBound(rec) then return true end
    local method=rec.slot.setup_view
    if type(rec.slot)~="table" or type(method)~="function" then return false end
    rec.ownMethod=rawget(rec.slot,"setup_view")
    rec.wrap=function(self,...)
      if self==rec.slot and hidden[rec.id]==rec then
        -- Bump first: a tick already holding a snapshot must not publish it once
        -- this slot is committed to a rebind.
        epoch=epoch+1
        -- The list callback calls setup_view before replacing UniqueID and item.
        pcall(release,rec.id)
        catalog,keys=nil,nil
        pcall(hide,"slot rebinding")
      end
      return method(self,...)
    end
    rawset(rec.slot,"setup_view",rec.wrap)
    hidden[rec.id]=rec
    layoutDirty=true
    rec.go:SetActive(false)
    return true
  end
  local function desiredSlots(rows,vr,dragging,ct)
    local desired,groups,seen={}, {}, {}
    local cid=ct.gameObject:GetInstanceID()
    for i,row in ipairs(rows) do
      local tr=row.transform and slotOf(row.transform,cid)
      if tr~=nil then
        local go=tr.gameObject
        local id=go:GetInstanceID()
        if seen[id] then return nil end
        seen[id]=true
        local old=hidden[id]
        local ours=old~=nil and rawequal(old.slot,row.slot) and rawequal(old.item,row.item)
        if go.activeSelf==true or ours then
          local key=keys[i]
          local group=groups[key]
          if group==nil then group={members={}} groups[key]=group end
          -- Visibility is measured on the slot root, not the icon root: the icon is
          -- inset inside the cell and reports itself gone while the cell is visible.
          local rec={id=id,go=go,slot=row.slot,uid=row.nativeId,item=row.item,group=group,
            inViewport=locate(tr,vr,ours or dragging)~=nil}
          group.members[#group.members+1]=rec
          if group.representative==nil and go.activeSelf and rec.inViewport then
            group.representative=rec
          end
        end
      end
    end
    for _,group in pairs(groups) do
      local first=group.representative
      -- If the first data row is virtual/offscreen, keep a realized visible slot instead.
      if first~=nil then
        local second=nil
        if dragging then
          local nextNear,previousNear,passedFirst
          for _,rec in ipairs(group.members) do
            if rec==first then
              passedFirst=true
            elseif rec.inViewport then
              second=rec
              break
            elseif passedFirst then
              nextNear=nextNear or rec
            else
              previousNear=rec
            end
          end
          second=second or nextNear or previousNear
        end
        for _,rec in ipairs(group.members) do
          if rec~=first and rec~=second then desired[rec.id]=rec end
        end
      end
    end
    return desired
  end
  local function tick()
    if disposed or waiting then return end
    if not equipTr.gameObject.activeInHierarchy then
      discard("equipment list hidden")
      return
    end
    local rows,reason,dragging=binding.read(bridge,equipTr,true)
    if rows==nil then discard(reason) rebuild() return end
    if not sameRows(catalog,rows) then
      discard("waiting for stable bindings")
      local check=epoch
      rebuild()
      if check==epoch then catalog=rows end
      return
    end
    if keys==nil then
      local excluded
      keys,excluded=equiv.classify(bridge,rows)
      local reasons,n={},#rows
      for name,count in pairs(excluded) do
        reasons[#reasons+1]=name..":"..count
        n=n-count
      end
      table.sort(reasons)
      eligible=n
      exclusions=#reasons>0 and table.concat(reasons,",") or "none"
    end
    local vr,ct=viewport.rect,content()
    if vr.width<=0 or vr.height<=0 or ct==nil then
      discard("waiting for viewport") rebuild() return
    end
    local desired=desiredSlots(rows,vr,dragging,ct)
    if desired==nil then discard("ambiguous slot mapping") rebuild() return end
    local check=epoch
    for id,rec in pairs(hidden) do
      local nextRec=desired[id]
      if nextRec==nil or not rawequal(nextRec.slot,rec.slot) or not rawequal(nextRec.item,rec.item)
          or nextRec.uid~=rec.uid then
        release(id)
        if check~=epoch then return end
      end
    end
    local degraded=false
    for _,rec in pairs(desired) do
      local g=rec.group
      if g~=nil and g.degraded then
        -- This stack is already expanded for this frame.
      elseif not conceal(rec) then
        -- Unobservable slot: expand its whole stack and leave the others alone.
        if g~=nil then
          g.degraded=true
          for id,own in pairs(hidden) do
            if own.group==g then pcall(release,id) end
          end
        end
        degraded=true
      end
      if check~=epoch then return end
    end
    if degraded then hide("slot not observable") end
    if dragging then hide("dragging; one extra slot per stack") end
    if layoutDirty then
      hide("waiting for layout")
      rebuild()
      return
    end
    if dragging then return end
    local publish={}
    for i,row in ipairs(rows) do
      publish[i]={itemId=row.itemId,groupKey=keys[i],anchor=locate(row.transform,vr)}
    end
    if samePlacement(placements,publish) then return end
    local token=layer:invalidate()
    placements=nil
    local ok,count=layer:publish(token,publish)
    if ok then
      placements=publish
      result.status=("badge preview: backpack=%d badges=%d eligible=%d excluded=%s"):format(#rows,count,eligible,exclusions)
    end
  end

  onStart=function()
    if disposed then return end
    waiting=true
    pcall(discard,"inventory changing")
  end
  onDone=function()
    if disposed then return end
    waiting=false
    pcall(discard,"waiting for stable bindings")
  end
  function result:invalidate()
    if disposed then return end
    discard("waiting for stable bindings")
  end
  function result:dispose()
    if disposed then return end
    disposed=true
    if subscribedStart then pcall(function() notify.remove_notify_handler(group,start,onStart,owner) end) end
    if subscribedDone then pcall(function() notify.remove_notify_handler(group,done,onDone,owner) end) end
    if scroll~=nil then pcall(function() scroll.onValueChanged:RemoveListener(onScroll) end) end
    if ticker~=nil then pcall(function() ticker:ClearLateTickCallback() end) end
    pcall(discard,"disposed")
    pcall(rebuild)
    if layer~=nil then pcall(function() layer:dispose() end) end
    if tickerGo~=nil then pcall(U.Object.Destroy,tickerGo) end
  end

  local ok,initFail=pcall(function()
    layer=badges.new(U,viewport)
    tickerGo=U.GameObject("WDHO_StackBadgeTicker")
    tickerGo.transform:SetParent(equipTr,false)
    ticker=assert(tickerGo:AddComponent(typeof(bridge.RPG.Client.MonoPerformanceUITransfer)))
    local tickFrame=0
    ticker:SetLateTickCallback(function()
      if disposed or checking then return end
      tickFrame=(tickFrame+1)%3
      if tickFrame~=0 then return end
      checking=true
      local good=pcall(tick)
      checking=false
      if not good then pcall(discard,"binding or raw properties unavailable") pcall(rebuild) end
    end,owner)
    subscribedStart=true
    notify.add_notify_handler(group,start,onStart,owner)
    subscribedDone=true
    notify.add_notify_handler(group,done,onDone,owner)
    local scrollTr=equipTr:Find("ScrollView")
    if scrollTr~=nil then
      scroll=scrollTr.gameObject:GetComponent(typeof(U.UI.ScrollRect))
      if scroll~=nil then
        onScroll=function()
          if not disposed then pcall(hide,"viewport moved") end
        end
        scroll.onValueChanged:AddListener(onScroll)
      end
    end
  end)
  if not ok then result:dispose() return nil,"badge preview: INIT FAIL "..tostring(initFail) end
  return result
end

return M

end)()
local function __equipbar_badge_preview(bridge,G,equipTr,viewport)
  return EquipBadgeRuntime.new(bridge,G,equipTr,viewport,EquipBinding,EquipEquivalence,StackBadgeLayer)
end
local bridge=CS
if bridge==nil then return "wait unity" end
-- 适配：G = 游戏全局 Lua 表 _G.G；判等类别用 Basic(1)；xlua 实例方法需 lambda 包裹。
local G = _G.G
if type(G)~="table" or G.NotifyManager==nil or G.CS==nil then return "wait notify" end
local U=bridge.UnityEngine
if U==nil then return "wait unity" end
local PC="UIRoot/Page/GridFightS2TeamEditPage(Clone)/Root/PanelContent"
local state=_G.Q_EQUIP_STATE
local function disposeBadge()
  if state~=nil and state.badge~=nil then
    local running=state.badge
    state.badge,state.badgeRevision,state.badgeEquip,state.badgeViewport=nil,nil,nil,nil
    running:dispose()
  end
end
local pc=U.GameObject.Find(PC)
if pc==nil then
  if state~=nil then state.dragPointer=nil end
  disposeBadge()
  return "idle"
end
local id=pc:GetInstanceID()
local revision=__equipbar_revision or 0
if state==nil or state.panel~=id then
  disposeBadge()
  state={panel=id}
  _G.Q_EQUIP_STATE=state
end

local bpTr=pc.transform:Find("EquipBackpack")
if bpTr==nil then disposeBadge() return "wait bp" end
local eqTr=bpTr:Find("EquipList")
local consTr=bpTr:Find("ConsumableList")
if eqTr==nil or consTr==nil then disposeBadge() return "wait lists" end
local bp=bpTr.gameObject
local equip,consumables=eqTr.gameObject,consTr.gameObject
local backpackId,equipId,consumablesId=bp:GetInstanceID(),equip:GetInstanceID(),consumables:GetInstanceID()
local viewport=eqTr:Find("ScrollView/Viewport")
local viewportId=viewport and viewport.gameObject:GetInstanceID()
if state.badge~=nil and
    (state.badgeRevision~=revision or state.badgeEquip~=equipId or state.badgeViewport~=viewportId) then
  disposeBadge()
end
local function status()
  if __equipbar_badge_preview~=nil then
    if viewport==nil then disposeBadge() return "badge preview: waiting for viewport" end
    if state.badge==nil then
      local ok,new,reason=pcall(__equipbar_badge_preview,bridge,G,eqTr,viewport)
      if not ok then return "badge preview: stock UI notifications or ticker unavailable" end
      if new==nil then return reason end
      state.badge,state.badgeRevision,state.badgeEquip=new,revision,equipId
      state.badgeViewport=viewportId
    end
    return state.badge.status
  end
  if __equipbar_binding_preview~=nil and equip.activeSelf then
    return __equipbar_binding_preview.report(bridge,eqTr)
  end
  return "ready"
end

local btnTr=pc.transform:Find("EquipToggleBtn2")
local btn=btnTr and btnTr.gameObject
local R=typeof(U.RectTransform)
local T=typeof(U.EventSystems.EventTrigger)
local I=typeof(U.UI.Image)
local trigger=btn and btn:GetComponent(T)
local mounted=btn~=nil and btn.activeSelf and state.button==btn:GetInstanceID()
    and btn:GetComponent(R)~=nil and btn:GetComponent(I)~=nil
    and trigger~=nil and trigger.triggers.Count==4
if not mounted then state.dragPointer=nil end

-- 不在轮询期间重绑已挂载的按钮，修订变更也等本次拖动结束再重绑。
if mounted and state.dragPointer~=nil then return "ready" end
if mounted and state.revision==revision and state.backpack==backpackId
    and state.equip==equipId and state.consumables==consumablesId then
  state.syncIndicators()
  return status()
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
  local panelRect=pc:GetComponent(R)
  local canvas=pc:GetComponentInParent(typeof(U.Canvas))
  if panelRect==nil or panelRect.rect.width<44 or panelRect.rect.height<44 then error("invalid panel rect") end
  if canvas==nil or canvas.scaleFactor<=0 then error("invalid canvas scale") end

  local function clampPos(x,y)
    local rect=panelRect.rect
    local mx=math.max(22,rect.width-22)
    local my=math.max(22,rect.height-22)
    return math.max(-mx,math.min(-22,x)),math.max(-my,math.min(-22,y))
  end

  local center=U.Vector2(0.5,0.5)
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
  local face=component(btn,I,"button image")
  face.color=U.Color(1,1,1,0.75)
  face.raycastTarget=true

  -- 同一对象若来自 v1.0.2 的热重载，旧 Button/箭头已不再承担职责。
  local oldButton=btn:GetComponent(typeof(U.UI.Button))
  if oldButton~=nil then
    oldButton.onClick:RemoveAllListeners()
    oldButton.enabled=false
  end
  local arrow=btn.transform:Find("Arrow")
  if arrow~=nil then arrow.gameObject:SetActive(false) end

  local inner=child(btn.transform,"EquipToggleInner")
  geometry(component(inner,R,"inner rect"),center,34,34)
  local fill=component(inner,I,"inner image")
  fill.color=U.Color(0,0,0,0.95)
  fill.raycastTarget=false

  local function indicator(name,y)
    local obj=child(btn.transform,name)
    local rect=component(obj,R,"indicator rect")
    geometry(rect,center,18,7)
    rect.anchoredPosition=U.Vector2(0,y)
    local image=component(obj,I,"indicator image")
    image.raycastTarget=false
    obj.transform:SetAsLastSibling()
    return image
  end
  local eqIndicator=indicator("BarEquip",7)
  local consIndicator=indicator("BarCons",-7)
  local lit,dim=U.Color(1,1,1,1),U.Color(0.35,0.35,0.35,1)
  local eqWasOn,consWasOn
  local function syncIndicators()
    local eqOn,consOn=equip.activeSelf,consumables.activeSelf
    if eqOn~=eqWasOn then eqIndicator.color=eqOn and lit or dim eqWasOn=eqOn end
    if consOn~=consWasOn then consIndicator.color=consOn and lit or dim consWasOn=consOn end
  end

  -- 保留基线对旧 Content 锚点的校正，不改任何子槽的状态。
  if state.layout~=backpackId then
    local ct=bpTr:Find("EquipList/ScrollView/Viewport/Content")
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

  local E=U.EventSystems
  local left,right=E.PointerEventData.InputButton.Left,E.PointerEventData.InputButton.Right
  local function toggle(d)
    if d.eligibleForClick==false then return end
    -- BeginDrag 已取消同次点击；新的真实左键点击可解开丢失 EndDrag 留下的状态。
    if d.button==left then state.dragPointer=nil end
    local tr=pc.transform:Find("EquipBackpack")
    if tr==nil or tr.gameObject:GetInstanceID()~=backpackId then return end
    local currentEquip,currentCons=tr:Find("EquipList"),tr:Find("ConsumableList")
    if currentEquip==nil or currentCons==nil
        or currentEquip.gameObject:GetInstanceID()~=equipId
        or currentCons.gameObject:GetInstanceID()~=consumablesId then return end
    if d.button==left then
      if state.badge~=nil then pcall(state.badge.invalidate,state.badge) end
      equip:SetActive(not equip.activeSelf)
    elseif d.button==right then
      consumables:SetActive(not consumables.activeSelf)
    else
      return
    end
    syncIndicators()
  end

  local function beginDrag(d)
    if d.button~=left then return end
    d.eligibleForClick=false
    if state.dragPointer==nil or state.dragPointer==d.pointerId then state.dragPointer=d.pointerId end
  end
  local function drag(d)
    if d.button~=left or state.dragPointer==nil or d.pointerId~=state.dragPointer then return end
    local p=r.anchoredPosition
    local scale=canvas.scaleFactor
    if scale<=0 then return end
    local nx,ny=clampPos(p.x+d.delta.x/scale,p.y+d.delta.y/scale)
    r.anchoredPosition=U.Vector2(nx,ny)
  end
  local function endDrag(d)
    if d.button~=left or state.dragPointer==nil or d.pointerId~=state.dragPointer then return end
    state.dragPointer=nil
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
  bind(ids.PointerClick,toggle)
  if tg.triggers.Count~=4 then error("incomplete button listeners") end
  syncIndicators()
  btn:SetActive(true)
  if not btn.activeSelf then error("button activation failed") end
  state.button,state.backpack=buttonId,backpackId
  state.equip,state.consumables=equipId,consumablesId
  state.syncIndicators,state.revision=syncIndicators,revision
end)
if not ok then return "partial: "..tostring(err) end
return status()
