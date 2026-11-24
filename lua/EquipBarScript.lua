local __pr=(function()
  local S=_G.Q_EQUIP_PROBE
  if type(S)~="table" or type(S.buf)~="table" or type(S.last)~="table" then
    S={buf={},n=0,last={}}
    _G.Q_EQUIP_PROBE=S
  end
  return S
end)()
local function zprobe(s)
  if __pr.n>=100000 then return end
  __pr.n=__pr.n+1
  if #__pr.buf<48 then __pr.buf[#__pr.buf+1]=tostring(s) end
end
local function zprobeOnce(tag,val)
  if __pr.last[tag]==val then return false end
  __pr.last[tag]=val
  return true
end
local function zprobeDrain()
  if #__pr.buf==0 then return "" end
  local s=table.concat(__pr.buf," ;; ")
  __pr.buf={}
  return s
end
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

function M.read(bridge,equipTr,requireDragIdle,packName)
  local client=bridge.RPG.Client
  local page=client.GlobalVars.s_UIManager:GetPageByName("GridFightPreparationPage")
  local pageData=page and page.LuaTable
  if pageData==nil then return nil,"waiting for preparation page" end
  local binder=pageData._binder
  local name=packName or "panel_equip_item_pack"
  local pack=binder and binder[name]
  if pack==nil then return nil,"waiting for equipment panel" end
  local okRoot,root=pcall(function() return pack:get_root_transform() end)
  if not okRoot or root==nil or root.gameObject:GetInstanceID()~=equipTr.gameObject:GetInstanceID() then
    return nil,"equipment panel changed"
  end
  if requireDragIdle then
    local okDrag=pcall(function()
      local drag=pack:_get_drag_panel()
      if drag==nil or drag:is_dragging()~=false then error("busy") end
    end)
    if not okDrag then return nil,"waiting for drag idle" end
  end
  local data=pack._equip_items or pack._items
  if type(data)~="table" then return nil,"waiting for equipment data" end
  local rows,seen={},{}
  local n=#data
  for i in pairs(data) do
    if type(i)~="number" or i%1~=0 or i<1 or i>n then return nil,"invalid list" end
  end
  local hasSlotFn=pcall(function() return pack.get_slot_panel_by_index end) and pack.get_slot_panel_by_index~=nil
  local content=nil
  if not hasSlotFn then content=equipTr:Find("ScrollView/Viewport/Content") end
  for i=1,n do
    local item=data[i]
    if item==nil then return nil,"invalid list" end
    local nativeId=item.UniqueID
    local id=uid(nativeId)
    if seen[id] then return nil,"duplicate uid" end
    seen[id]=true
    local row={itemId=id,item=item}
    if hasSlotFn then
      local okSlot,slot=pcall(function() return pack:get_slot_panel_by_index(i) end)
      if okSlot and slot~=nil then
        local okBind,good=pcall(function()
          local panel=slot:get_equip_item_panel()
          local bound=panel and panel:get_equip_item()
          if bound==nil or slot:get_equip_uid()~=nativeId
              or bound.UniqueID~=nativeId or not rawequal(bound,item) then return false end
          local tr=panel:get_root_transform()
          if tr==nil or not tr:IsChildOf(equipTr) then return false end
          row.transform=tr
          return true
        end)
        if not okBind or not good then rows.unstable=true end
      end
    elseif content~=nil then
      local okChild,childTr=pcall(function() return content:GetChild(i-1) end)
      if okChild and childTr~=nil then row.transform=childTr end
    end
    rows[i]=row
  end
  return rows
end

function M.pack(bridge,packName)
  local client=bridge.RPG.Client
  local page=client.GlobalVars.s_UIManager:GetPageByName("GridFightPreparationPage")
  local pageData=page and page.LuaTable
  if pageData==nil then return nil end
  local binder=pageData._binder
  local name=packName or "panel_equip_item_pack"
  return binder and binder[name] or nil
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
  local categories=game.GridFightEquipCategory
  local basic,craftable=categories.Basic,categories.Craftable
  if basic==nil or craftable==nil then return nil,"not-basic" end
  local equipCategory=category.EquipCategory
  -- Basic/Craftable: 简易/进阶装备。
  -- Emblem(星辉) / Crown(特权) / Radiant(光耀)：用户要求「同样的也叠起来」，
  -- 这些类别同样按 ItemID 归组；GoldTrash(废料) 等仍排除。
  -- EquipCategory 是枚举值（比较用 tostring 才能同时兼容数字和 xLua 枚举）。
  local allowed={}
  for _,name in ipairs({"Basic","Craftable","Emblem","Crown","TraitSpecial","Artifacts","Radiant","Support","Other","FateEquip","Intrinsic","SpotLightEquip","Material","Trash","GoldTrash"}) do
    local v=categories[name]
    if v~=nil then allowed[tostring(v)]=true end
  end
  if not allowed[tostring(equipCategory)] then return nil,"not-basic" end
  local id=item.ItemID
  if not integer(id) or id<=0 or id~=cfg.ItemConfig.ItemID then return nil,"config" end
  -- 只保留「类别白名单 + ItemID 合法」：来源/临时/已穿戴/额外词条/框/售格
  -- 都是实例状态或显示差异，和「是不是同一种装备」无关，会把大量装备挡在折叠之外。
  return {id=id,raw={},category=equipCategory}
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
  local result,byName,excluded={},{},{}
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
      -- 分组按「物品名」优先：蓝钻/红钻/财富宝钻这类每件 ItemID 不同但名字相同，
      -- 只按 ItemID 分组永远叠不起来；名字取不到时退回 ItemID。
      -- 崩铁每件装备属性固定，同名即同物；但特权/普通/羁绊三类必须各自独立，
      -- 所以分组键 = 类别编号 + 物品名（名字取不到时退回 ItemID）。
      local cid=profile.category
      local okName,nm=pcall(function()
        local rowCfg=row.item.EquipItemConfig
        local ic=rowCfg and rowCfg.ItemConfig
        if ic==nil then return nil end
        return bridge.RPG.Client.TextmapStatic.GetText(ic.ItemName)
      end)
      if not okName or type(nm)~="string" or nm=="" then nm=nil end
      -- 羁绊装备（阿哈/星核猎手等角色的专属装备）与普通装备同名同 ItemID，
      -- 唯一区别是来源 SourceType（游戏里图标右下角有面具笑脸、可出售）。
      -- 不同羁绊来源必须各自成组，所以键里带完整的 SourceType 文本。
      local trait="0"
      local okSrc,srcv=pcall(function() return tostring(row.item.SourceType) end)
      if okSrc and type(srcv)=="string" and srcv:sub(1,11)=="TraitEffect" then
        trait=srcv
      end
      local key
      if nm~=nil then
        key="c"..tostring(cid).."|t:"..trait.."|n:"..nm
      else
        key="c"..tostring(cid).."|t:"..trait.."|item:"..tostring(profile.id)
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
-- Own the ticker, listeners and overlays. Do not edit any stock slot or label.
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

function M.new(bridge,G,equipTr,viewport,binding,equiv,badges,packName)
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
    local restoreDone=false
  local lastSlots=nil
  -- 每组「当前可见的那一格」的实例 ID：组内数量变化时优先保持同一格可见，
  -- 否则代表格会跳走，看起来就像展开后位置不对。
  local repByKey={}
  local keyCache={}
  local curMapped,curFb=0,0
local origSize={}
local function softHide(go,on)
  pcall(function()
    local cg=go:GetComponent(typeof(U.CanvasGroup))
    if cg==nil then cg=go:AddComponent(typeof(U.CanvasGroup)) end
    local rt=go:GetComponent(rectType)
    if on then
      if rt~=nil and origSize[go]==nil then
        local sd=rt.sizeDelta
        origSize[go]={sd.x,sd.y}
        rt.sizeDelta=U.Vector2(0,0)
      end
      cg.alpha=0 cg.blocksRaycasts=false cg.interactable=false
    else
      local o=origSize[go]
      if rt~=nil and o~=nil then
        rt.sizeDelta=U.Vector2(o[1],o[2])
        origSize[go]=nil
      end
      cg.alpha=1 cg.blocksRaycasts=true cg.interactable=true
    end
  end)
end
  local result={status="badge preview: waiting for stable bindings"}
  local rectType=typeof(U.RectTransform)
  local dragGrace=0
  local stLast=0
  local holdTicks=0
  local hoverKey=nil
  local dragRevealKey=nil
  -- 每组「我们亲手隐藏的那一格」。拖动分副本时优先用它：这格一定同组同一件，
  -- 不会像游戏复用池里的空格子那样还留着上一件装备的画（红钻位置冒出蓝钻）。
  local hiddenSlotOf={}
  local function mouseHeld()
    local ok,held=pcall(function() return U.Input.GetMouseButton(0) end)
    return ok and held==true
  end
  -- 只恢复「我们自己关掉过」的格子，绝不碰游戏自己的空位/池子。
  local function restoreLast()
    if lastSlots==nil then return end
    local any=false
    for _,rec in ipairs(lastSlots) do
      if rec.slot~=nil and rec.slot.gameObject~=nil and rec.slot.gameObject.activeSelf~=true then
        rec.slot.gameObject:SetActive(true)
        any=true
      end
    end
    lastSlots=nil
    if any then
      local ct=equipTr:Find("ScrollView/Viewport/Content")
      if ct~=nil then
        local cr=ct.gameObject:GetComponent(rectType)
        if cr~=nil then pcall(function() U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(cr) end) end
      end
    end
  end

  local function hide(reason)
    if placements~=nil then placements=nil layer:invalidate() end
    result.status="badge preview: "..reason
  end

  local function locate(tr,vr)
    if tr==nil or tr.gameObject.activeInHierarchy~=true then return nil end
    local r=tr.gameObject:GetComponent(rectType)
    if r==nil then return nil end
    local edge=viewport:InverseTransformPoint(r:TransformPoint(U.Vector3(r.rect.xMax,r.rect.yMin,0)))
    local x,y=(edge.x-vr.xMin)/vr.width,(edge.y-vr.yMin)/vr.height
    if x>=0 and x<=1 and y>=0 and y<=1 then return {x=x,y=y} end
    return nil
  end

  local function ct2Lookup()
    local ct=equipTr:Find("ScrollView/Viewport/Content")
    return ct and ct.gameObject or equipTr.gameObject
  end
  local suppressed=false
  function result:suppress(v)
    suppressed=v==true
    if suppressed and placements~=nil then
      placements=nil
      pcall(function() layer:invalidate() end)
    end
  end
  local function tick()
    if disposed then return end
    do
      local ST=_G.Q_EQUIP_STATE
      if ST~=nil and type(ST.onFrame)=="function" then pcall(ST.onFrame) end
    end
    if _G.Q_EQUIP_STATE~=nil and _G.Q_EQUIP_STATE.vanilla==true then
      pcall(restoreLast)
      if placements~=nil then placements=nil pcall(function() layer:invalidate() end) end
      result.status="badge preview: vanilla mode (stacking off)"
      return
    end
    if suppressed then
      if placements~=nil then placements=nil pcall(function() layer:invalidate() end) end
      result.status="badge preview: bar hidden by user"
      return
    end
    if not equipTr.gameObject.activeInHierarchy then
      catalog,keys=nil,nil
      hide("equipment list hidden")
      return
    end
    local rows,reason=binding.read(bridge,equipTr,packName==nil,packName)
    if rows==nil then
      dragGrace=0
      catalog,keys=nil,nil hide(reason) return
    end
    if keys==nil then
      -- 面板重建后旧的两拍稳定判定会让整排装备先展开一两秒。
      -- 用 itemId→分组 缓存，只要能全部命中就直接隐藏，不等稳定。
      local cached,okAll={},true
      for ci=1,#rows do
        local ck=keyCache[rows[ci].itemId]
        if ck==nil then okAll=false break end
        cached[ci]=ck
      end
      if okAll and #cached==#rows then
        catalog,keys=rows,cached
      end
    end
    if not sameRows(catalog,rows) then
      hide("waiting for stable bindings")
      catalog,keys=rows,nil
      return
    end
    if keys==nil then
      local excluded
      keys,excluded=equiv.classify(bridge,rows)
      for ci=1,#rows do
        if keys[ci]~=nil then keyCache[rows[ci].itemId]=keys[ci] end
      end
      local reasons,n={},#rows
      for name,count in pairs(excluded) do
        reasons[#reasons+1]=name..":"..count
        n=n-count
      end
      table.sort(reasons)
      eligible=n
      exclusions=#reasons>0 and table.concat(reasons,",") or "none"    end
    -- 折叠：鼠标按住、或拖动刚结束的几帧内一律不隐藏；开始拖动立刻全恢复。
    dragGrace=dragGrace+1
    local heldNow=mouseHeld()
    if heldNow then holdTicks=holdTicks+1 else holdTicks=0 end
    -- Input.GetMouseButton 在 IL2CPP 下有时会一直返回 true（点了之后不再复位），
    -- 那样整段隐藏逻辑会被永久跳过，表现就是「一操作就全展开」。
    -- 连续按住超过约 2 秒就当作失灵，照常隐藏。
    local heldStuck=heldNow and holdTicks>40
    if (heldNow and not heldStuck) or dragGrace<2 then
      -- 拖动中/刚落手：完全不碰格子，既不隐藏也不展开。
      -- 例外：简易装备要和同款合成，拖动时给每个简易组额外放出一个副本。
      if heldNow and not heldStuck and keys~=nil then
        pcall(function()
          local ctd=equipTr:Find("ScrollView/Viewport/Content")
          if ctd==nil then return end
          local cidd=ctd.gameObject:GetInstanceID()
          local function slotOf(tr)
            local t=tr
            while t~=nil do
              local pp=t.parent
              if pp==nil then break end
              if pp.gameObject:GetInstanceID()==cidd then return t end
              t=pp
            end
            return nil
          end
          local mk,how=hoverKey,"hover"
          if type(mk)~="string" or mk:sub(1,9)=="excluded" then mk,how=nil,"none" end
          -- 需要"拖动时分出一个"来合成的只有两类：
          --   简易装备 Basic（含阿哈/星核猎手那类羁绊简易）
          --   钻石类 Material（蓝钻/红钻，用于合成流派星徽）
          -- 星辉/特权/进阶/财富宝钻都不能自合成，不放副本。
          local wantReveal=false
          if mk~=nil then
            if mk:sub(1,6)=="cBasic" then
              wantReveal=true
            elseif mk:sub(1,9)=="cMaterial" and not mk:find("财富宝钻",1,true) then
              wantReveal=true
            end
          end
          if not wantReveal then
            local lnb=("DRG skip-nonbasic mk=%s"):format(tostring(mk))
            if zprobeOnce("drg",lnb) then zprobe(lnb) end
            return
          end
          local target=nil
          if mk~=nil then
            for mi=1,#rows do if keys[mi]==mk then target=mi break end end
          end
          if target==nil then
            local okP,pk=pcall(function() return binding.pack(bridge,packName) end)
            if okP and pk~=nil then
              local okD,dg=pcall(function() return pk:_get_drag_panel() end)
              if okD and dg~=nil then
                local ev=dg._drag_event
                if type(ev)=="table" then
                  local uid=nil
                  for _,f in ipairs({"uid","item_uid","equip_uid","UniqueID"}) do
                    pcall(function() if ev[f]~=nil then uid=tostring(ev[f]) end end)
                    if uid~=nil then break end
                  end
                  if uid~=nil then
                    for mi=1,#rows do
                      if tostring(rows[mi].item.UniqueID)==uid then target=mi mk=keys[mi] how="event" break end
                    end
                  end
                end
              end
            end
          end
          if target==nil then
            local ln0=("DRG none mk=%s how=%s"):format(tostring(hoverKey),tostring(how))
            if zprobeOnce("drg",ln0) then zprobe(ln0) end
            return
          end
          -- 一次拖动只放一个副本：按住不放时不要每拍再放一个，否则会一组组全展开
          if dragRevealKey==mk then
            local lns=("DRG skip mk=%s"):format(tostring(mk))
            if zprobeOnce("drg",lns) then zprobe(lns) end
            return
          end
          local done=false
          -- 找到该组当前可见的那一格，把分出来的副本排到它后面，位置上就挨在一起
          local keeperIdx,keeperName=nil,nil
          pcall(function() keeperName=tostring(rows[target].item.Name) end)
          for mi=1,#rows do
            if keys[mi]==mk then
              local mtk=rows[mi].transform
              if mtk~=nil then
                local slk=slotOf(mtk)
                if slk~=nil and slk.gameObject.activeSelf==true then
                  keeperIdx=slk:GetSiblingIndex()
                  break
                end
              end
            end
          end
          -- 副本候选：同组 + 同名字 + 当前隐藏；优先挑离代表格最近的那一格。
          -- 隐藏格子是游戏复用的池子，随便挑一格激活可能还是上一次的画（红钻位置冒出蓝钻）。
          local bestIdx,bestDist=nil,nil
          for mi=1,#rows do
            if keys[mi]==mk and mi~=target then
              local sameName=true
              if keeperName~=nil then
                local rn=nil
                pcall(function() rn=tostring(rows[mi].item.Name) end)
                sameName=(rn==keeperName)
              end
              if sameName then
                local mt=rows[mi].transform
                if mt~=nil then
                  local slot=slotOf(mt)
                  if slot~=nil and slot.gameObject.activeSelf~=true then
                    local sib=slot:GetSiblingIndex()
                    local dist=sib
                    if keeperIdx~=nil then dist=math.abs(sib-keeperIdx) end
                    if bestDist==nil or dist<bestDist then bestDist=dist bestIdx=mi end
                  end
                end
              end
            end
          end
          local rvName="-"
          -- 优先用「我们自己隐藏过的那一格」：它一定是同组同一件，
          -- 不存在复用池里残留旧画面的问题。
          local rslot=hiddenSlotOf[mk]
          if rslot~=nil then
            local okAlive,go=pcall(function() return rslot.gameObject end)
            if not okAlive or go==nil or go.activeSelf==true then rslot=nil else rvName="cached" end
          end
          if rslot==nil and bestIdx~=nil then
            pcall(function() rvName=tostring(rows[bestIdx].item.Name) end)
            rslot=slotOf(rows[bestIdx].transform)
          end
          if rslot~=nil then
            rslot.gameObject:SetActive(true)
            softHide(rslot.gameObject,false)
            if keeperIdx~=nil then
              pcall(function() rslot:SetSiblingIndex(keeperIdx+1) end)
            end
            done=true
          end
          if done then
            dragRevealKey=mk
            local crd=ctd.gameObject:GetComponent(rectType)
            if crd~=nil then U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(crd) end
          end
          if done or zprobeOnce("drg",tostring(mk))~=nil then
            zprobe(("DRG mk=%s done=%s keeper=%s keepName=%s rv=%s rvName=%s how=%s"):format(tostring(mk),tostring(done),tostring(keeperIdx),tostring(keeperName),tostring(bestIdx),tostring(rvName),tostring(how)))
          end
        end)
      end
    else
      dragRevealKey=nil
      local ct=equipTr:Find("ScrollView/Viewport/Content")
      if ct~=nil then
        local cid=ct.gameObject:GetInstanceID()
        local function slotOf(tr)
          local t=tr
          while t~=nil do
            local p=t.parent
            if p==nil then break end
            if p.gameObject:GetInstanceID()==cid then return t end
            t=p
          end
          return nil
        end
        -- 面板重建后，pack 里的槽位引用可能指向旧对象，而界面显示的是新对象；
        -- 这时按 Content 子物体顺序对齐（实测 si = idx + offset，offset 通常为 2）。
        local offTally,offset={},2
        for mi=1,#rows do
          local mt0=rows[mi].transform
          if mt0~=nil then
            local s0=slotOf(mt0)
            if s0~=nil then
              local d=s0:GetSiblingIndex()-(mi-1)
              offTally[d]=(offTally[d] or 0)+1
            end
          end
        end
        do
          local best=0
          for d,cnt in pairs(offTally) do
            if cnt>best then best=cnt offset=d end
          end
        end
        local groups,order={},{}
        local fbCount,mappedCount=0,0
        local restoredAny=false
        for mi=1,#rows do
          local mt=rows[mi].transform
          local slot=nil
          if mt~=nil then slot=slotOf(mt) end
          if slot~=nil then mappedCount=mappedCount+1 end
          if slot==nil then
            local ci=mi-1+offset
            local okc,ch=pcall(function() return ct:GetChild(ci) end)
            if okc and ch~=nil then slot=ch fbCount=fbCount+1 end
          end
          if slot~=nil then
            local mk=keys[mi]
            local g=groups[mk]
            if g==nil then g={} groups[mk]=g order[#order+1]=mk end
            g[#g+1]={idx=mi,slot=slot}
          end
        end
        curMapped,curFb=mappedCount,fbCount
        local recs,any={},false
        local reps={}
        for _,mk in ipairs(order) do
          local g=groups[mk]
          local prev=repByKey[mk]
          local keeper,found=nil,false
          if prev~=nil then
            for _,entry in ipairs(g) do
              if entry.slot.gameObject:GetInstanceID()==prev then keeper=entry.slot found=true break end
            end
          end
          if not found then keeper=g[1].slot end
          reps[mk]=keeper and keeper.gameObject:GetInstanceID() or nil
          for _,entry in ipairs(g) do
            recs[#recs+1]={slot=entry.slot}
            local keep=(entry.slot==keeper)
            if entry.slot.gameObject.activeSelf~=keep then
              if keep then
                entry.slot.gameObject:SetActive(true)
                softHide(entry.slot.gameObject,false)
              else
                softHide(entry.slot.gameObject,true)
                entry.slot.gameObject:SetActive(false)
                hiddenSlotOf[mk]=entry.slot
              end
              any=true
            end
          end
        end
        do
          local okm,mp=pcall(function() return U.Input.mousePosition end)
          if okm and mp~=nil then
            local cam=nil
            pcall(function()
              local cnv=viewport.gameObject:GetComponentInParent(typeof(U.Canvas))
              if cnv~=nil then cam=cnv.worldCamera end
            end)
            do
              for mi=1,#rows do
                local mt=rows[mi].transform
                local slot=nil
                if mt~=nil then slot=slotOf(mt) end
                -- 只认当前真正显示的格子：被我们隐藏的格子还留着旧坐标，
                -- 列表重排后它的旧矩形可能正好压在别的格子上，会认错组（红钻→蓝钻）。
                if slot~=nil and slot.gameObject.activeSelf==true then
                  local rr=nil
                  pcall(function() rr=slot.gameObject:GetComponent(rectType) end)
                  if rr~=nil then
                    local c1=U.RectTransformUtility.WorldToScreenPoint(cam,rr:TransformPoint(U.Vector3(rr.rect.xMin,rr.rect.yMin,0)))
                    local c2=U.RectTransformUtility.WorldToScreenPoint(cam,rr:TransformPoint(U.Vector3(rr.rect.xMax,rr.rect.yMax,0)))
                    local xmin,xmax=math.min(c1.x,c2.x),math.max(c1.x,c2.x)
                    local ymin,ymax=math.min(c1.y,c2.y),math.max(c1.y,c2.y)
                    if mp.x>=xmin and mp.x<=xmax and mp.y>=ymin and mp.y<=ymax then
                      hoverKey=keys[mi] break
                    end
                  end
                end
              end
            end
          end
        end

        if zprobeOnce("hv",tostring(hoverKey)) then zprobe("HV "..tostring(hoverKey)) end
        repByKey=reps
        lastSlots=recs
        do
          local okP,pk=pcall(function() return binding.pack(bridge,packName) end)
          if okP and pk~=nil then
            local ks={}
            local okT=pcall(function()
              for k,v in pairs(pk) do
                local n=tostring(k)
                local tv=type(v)
                if tv=="table" or tv=="function" or n:find("drag") or n:find("item") or n:find("Item") then
                  ks[#ks+1]=n..":"..tv
                end
              end
            end)
            table.sort(ks)
            local ln="PK "..table.concat(ks,",")
            if #ln>900 then ln=ln:sub(1,900) end
            if zprobeOnce("pkkeys",ln) then zprobe(ln) end
            local okD,dg=pcall(function() return pk:_get_drag_panel() end)
            if okD and dg~=nil and type(dg)=="table" then
              local ks2={}
              for k,v in pairs(dg) do
                ks2[#ks2+1]=tostring(k)..":"..type(v)
              end
              table.sort(ks2)
              local ln2="DK "..table.concat(ks2,",")
              if #ln2>700 then ln2=ln2:sub(1,700) end
              if zprobeOnce("dkkeys",ln2) then zprobe(ln2) end
              do
                local ev=dg._drag_event
                if type(ev)=="table" then
                  local parts={}
                  for k,v in pairs(ev) do
                    local tv=type(v)
                    local sv=tostring(v)
                    if #sv>40 then sv=sv:sub(1,40).."..." end
                    parts[#parts+1]=tostring(k).."("..tv..")="..sv
                  end
                  table.sort(parts)
                  local ln3="DE "..table.concat(parts," ; ")
                  if #ln3>800 then ln3=ln3:sub(1,800) end
                  if zprobeOnce("dekeys",ln3) then zprobe(ln3) end
                else
                  if zprobeOnce("dekeys","DE nottable:"..type(dg._drag_event)) then zprobe("DE nottable:"..type(dg._drag_event)) end
                end
              end
            end
          end
        end
        if restoredAny then
          local cr2=ct.gameObject:GetComponent(rectType)
          if cr2~=nil then pcall(function() U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(cr2) end) end
        end        do
          local hid2=0
          for _,rec in ipairs(recs) do
            if rec.slot~=nil and rec.slot.gameObject~=nil and rec.slot.gameObject.activeSelf~=true then hid2=hid2+1 end
          end
          if __pr.last.hid~=hid2 then
            __pr.last.hid=hid2
            zprobe(("HCHG hidden=%d groups=%d rows=%d"):format(hid2,#order,#rows))
          end
        end        if any then
          local cr=ct.gameObject:GetComponent(rectType)
          if cr~=nil then pcall(function() U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(cr) end) end
        end
      end
    end
    if waiting then hide("inventory changing") return end
    local vr=viewport.rect
    if vr.width<=0 or vr.height<=0 then hide("waiting for viewport") return end
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
      local consInfo=""
      if state and state.badgeCons~=nil then
        consInfo=" | cons: "..tostring(state.badgeCons.status)
      end
      result.status=("badge preview: backpack=%d badges=%d eligible=%d excluded=%s"):format(#rows,count,eligible,exclusions)..consInfo
    end
  end

  onStart=function()
    if disposed then return end
    waiting=true
    catalog,keys=nil,nil
    pcall(hide,"inventory changing")
  end
  onDone=function()
    if disposed then return end
    waiting=false
    catalog,keys=nil,nil
    pcall(hide,"waiting for stable bindings")
  end
  function result:invalidate()
    if disposed then return end
    catalog,keys=nil,nil
    hide("waiting for stable bindings")
  end
  function result:dispose()
    if disposed then return end
    pcall(restoreLast)
    disposed=true
    if subscribedStart then pcall(function() notify.remove_notify_handler(group,start,onStart,owner) end) end
    if subscribedDone then pcall(function() notify.remove_notify_handler(group,done,onDone,owner) end) end
    if scroll~=nil then pcall(function() scroll.onValueChanged:RemoveListener(onScroll) end) end
    if ticker~=nil then pcall(function() ticker:ClearLateTickCallback() end) end
    if layer~=nil then pcall(function() layer:dispose() end) end
    if tickerGo~=nil then pcall(U.Object.Destroy,tickerGo) end
  end

  local ok,initFail=pcall(function()
    layer=badges.new(U,viewport)
    tickerGo=U.GameObject("WDHO_StackBadgeTicker")
    -- 挂在 EquipBackpack 而不是 EquipList：列表重建时 ticker 不会被一起销毁
    tickerGo.transform:SetParent(equipTr.parent or equipTr,false)
    ticker=assert(tickerGo:AddComponent(typeof(bridge.RPG.Client.MonoPerformanceUITransfer)))
    local tickFrame=0
    local depth=0
    ticker:SetLateTickCallback(function()
      depth=depth+1
      result.tickCount=depth
      if disposed or checking then return end
      tickFrame=(tickFrame+1)%3
      if tickFrame~=0 then return end
      checking=true
      local good=pcall(tick)
      checking=false
      if not good then catalog,keys=nil,nil pcall(hide,"binding or raw properties unavailable") end
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
local function __equipbar_badge_preview(bridge,G,equipTr,viewport,packName)
  return EquipBadgeRuntime.new(bridge,G,equipTr,viewport,EquipBinding,EquipEquivalence,StackBadgeLayer,packName)
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
  if state~=nil and state.badgeCons~=nil then
    local runningC=state.badgeCons
    state.badgeCons,state.badgeConsRevision,state.badgeConsViewport=nil,nil,nil
    pcall(function() runningC:dispose() end)
  end
  if state~=nil and state.badge~=nil then
    local running=state.badge
    state.badge,state.badgeRevision,state.badgeEquip=nil,nil,nil
    state.badgeTC,state.badgeTCAt=nil,nil
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
  local keepEq=state and state.equipWanted
  local keepCons=state and state.consWanted
  state={panel=id}
  state.equipWanted,state.consWanted=keepEq,keepCons
  _G.Q_EQUIP_STATE=state
end

local bpTrDump=pc.transform:Find("EquipBackpack")
if _G.Q_EQUIP_DUMPED==nil then
  _G.Q_EQUIP_DUMPED=true
  pcall(function()
    local page=bridge.RPG.Client.GlobalVars.s_UIManager:GetPageByName("GridFightPreparationPage")
    local binder=page and page.LuaTable and page.LuaTable._binder
    local pack=binder and binder.panel_equip_item_pack
    if pack==nil then zprobe("DUMP no pack") return end
    local names={}
    local okType=pcall(function()
      local t=pack:GetType()
      local ms=t:GetMethods()
      local n=0
      local len=(type(ms.Length)=="number") and ms.Length or 0
      for i=0,len-1 do
        local nm=ms[i] and ms[i].Name
        if nm~=nil then n=n+1 if n<=110 then names[#names+1]=nm end end
      end
      names[#names+1]="COUNT="..tostring(n)
    end)
    if not okType then
      local okIp=pcall(function()
        local n=0
        for _,mi in ipairs(pack:GetType():GetMethods()) do
          local nm=mi.Name
          n=n+1
          if n<=110 then names[#names+1]=nm end
        end
        names[#names+1]="COUNT="..tostring(n)
      end)
      if not okIp then names[#names+1]="reflect fail" end
    end
    zprobe("DUMP "..table.concat(names,","))
  end)
end
local bpTr=pc.transform:Find("EquipBackpack")
if bpTr==nil then return "wait bp" end
local eqTr=bpTr:Find("EquipList")
local consTr=bpTr:Find("ConsumableList")
if eqTr==nil or consTr==nil then return "wait lists" end
local bp=bpTr.gameObject
local equip,consumables=eqTr.gameObject,consTr.gameObject
-- 复制角色/领晶矿后游戏会把列表重新激活，用户手动关掉过的要保持关闭
-- 整条栏的软隐藏：除了 SetActive，还把 CanvasGroup 透明度压 0。
-- 游戏重新激活列表时，alpha 仍是 0，所以不会再闪一下整排装备。
local function softBar(go,on)
  pcall(function()
    local cg=go:GetComponent(typeof(U.CanvasGroup))
    if cg==nil then cg=go:AddComponent(typeof(U.CanvasGroup)) end
    if on then
      cg.alpha=0
      cg.blocksRaycasts=false
      cg.interactable=false
    else
      cg.alpha=1
      cg.blocksRaycasts=true
      cg.interactable=true
    end
  end)
end
-- 折叠整块区域但不 SetActive：用 LayoutElement.ignoreLayout 让它不参与父级排版，
-- 这样游戏把对象重新激活时不会引起整条栏重新排版（就是那一下「跳动」）。
local function barCollapse(go,on)
  pcall(function()
    local le=go:GetComponent(typeof(U.UI.LayoutElement))
    if le==nil then le=go:AddComponent(typeof(U.UI.LayoutElement)) end
    -- 隐藏时 ignoreLayout=true 并且 SetActive(false)：不占位、不进排版。
    -- 游戏事后把它重新激活，因为 ignoreLayout 仍是 true，也不会引起排版跳动。
    le.ignoreLayout=on==true
  end)
  softBar(go,on)
  pcall(function()
    go:SetActive(on~=true)
    if on~=true then
      local pr=go.transform.parent
      local prr=pr and pr:GetComponent(typeof(U.RectTransform))
      if prr~=nil then U.UI.LayoutRebuilder.ForceRebuildLayoutImmediate(prr) end
    end
  end)
end
if state~=nil and state.consWanted==nil then
  pcall(function()
    local cg0=consumables:GetComponent(typeof(U.CanvasGroup))
    if cg0~=nil and cg0.alpha<0.5 then barCollapse(consumables,false) end
  end)
end
if state~=nil then
  if state.equipWanted==false then
    if state.badge~=nil then pcall(state.badge.suppress,state.badge,true) end
    if equip.activeSelf==true then
    softBar(equip,true)
    equip:SetActive(false)
    state.rehideEq=(state.rehideEq or 0)+1
    end
  end
  if state.consWanted==false then
    barCollapse(consumables,true)
    state.rehideCons=(state.rehideCons or 0)+1
  end
end
local backpackId,equipId,consumablesId=bp:GetInstanceID(),equip:GetInstanceID(),consumables:GetInstanceID()
local function status()
  if state.badge~=nil and
      (__equipbar_badge_preview==nil or state.badgeRevision~=revision or state.badgeEquip~=equipId) then
    disposeBadge()
  end
  -- 看门狗：面板重建会连 ticker 一起销毁，而 state.badge 还挂着旧引用，
  -- 隐藏/角标就全部停摆（表现就是「一操作就全展开」）。tick 计数不涨就重建。
  if state.badge~=nil then
    local nowT=os.time()
    local tc=state.badge.tickCount
    if tc~=nil and tc~=state.badgeTC then
      state.badgeTC=tc
      state.badgeTCAt=nowT
    elseif type(state.badgeTCAt)=="number" and nowT-state.badgeTCAt>2 then
      disposeBadge()
    end
  end
  if __equipbar_badge_preview~=nil then
    -- 角标画在面板根上：蓝钻/财富宝钻那些格子在 EquipList 的 rect 之外，
    -- 用列表坐标系永远算不出合法锚点，改用覆盖整块面板的根节点。
    local viewport=pc.transform
    if viewport==nil then disposeBadge() return "badge preview: waiting for viewport" end
    if state.badge~=nil and state.badgeViewport~=viewport.gameObject:GetInstanceID() then disposeBadge() end
    if state.badge==nil then
      local ok,new,reason=pcall(__equipbar_badge_preview,bridge,G,eqTr,viewport)
      if not ok then return "badge preview: stock UI notifications or ticker unavailable" end
      if new==nil then return reason end
      state.badge,state.badgeRevision,state.badgeEquip=new,revision,equipId
      state.badgeViewport=viewport.gameObject:GetInstanceID()
    end    local zt=zprobeDrain()
    if zt~="" then return state.badge.status.."\n"..zt end
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
      softBar(equip,not equip.activeSelf)
      state.equipWanted=equip.activeSelf
      if state.badge~=nil and state.badge.suppress~=nil then
        pcall(state.badge.suppress,state.badge,state.equipWanted==false)
      end
    elseif d.button==right then
      zprobe(("RCLICK supp=%s vanilla=%s"):format(tostring(state.rSuppressClick),tostring(state.vanilla)))
      if state.rSuppressClick==true then state.rSuppressClick=false return end
      local cgC=consumables:GetComponent(typeof(U.CanvasGroup))
      local visibleC=(consumables.activeSelf==true) and (cgC==nil or cgC.alpha>0.5)
      barCollapse(consumables,visibleC)
      state.consWanted=not visibleC
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

  -- 长按右键（约 0.6 秒）在「mod 接管」和「游戏原生」之间切换：
  -- 原生模式下按钮不再拦截点击（raycastTarget=false），右键交回游戏自己处理。
  local function applyVanilla()
    local on=(state.vanilla==true)
    pcall(function()
      face.color=on and U.Color(1,1,1,0.4) or U.Color(1,1,1,0.75)
    end)
  end
  applyVanilla()
  local rHeldAt=nil
  state.onFrame=function()
    local now=0
    pcall(function() now=U.Time.realtimeSinceStartup end)
    local okH,held=pcall(function() return U.Input.GetMouseButton(1) end)
    held=(okH and held==true)
    if held then
      if rHeldAt==nil then
        rHeldAt=now
        state.rLongFired=false
        zprobe(("RCD %.2f"):format(now))
      elseif state.rLongFired~=true and (now-rHeldAt)>=1.0 then
        -- 按住到 0.6 秒就立刻切换：这时还没松手，PointerClick 还没触发，
        -- 抑制标记可以先设好，松手时那次点击就会被吞掉。
        state.rLongFired=true
        state.vanilla=not (state.vanilla==true)
        state.rSuppressClick=true
        state.rSuppressAt=now
        applyVanilla()
        zprobe(("RCLONG %.2f dur=%.2f vanilla=%s"):format(now,now-rHeldAt,tostring(state.vanilla)))
      end
    else
      if rHeldAt~=nil then
        rHeldAt=nil
        state.rReleaseAt=now
        zprobe(("RCU %.2f"):format(now))
      end
      -- 只从「松手之后」开始计时清除，按住多久都不会提前清掉抑制标记
      if state.rSuppressClick==true and state.rReleaseAt~=nil and (now-state.rReleaseAt)>0.8 then
        state.rSuppressClick=false
      end
    end
  end
  btn:SetActive(true)
  if not btn.activeSelf then error("button activation failed") end
  state.button,state.backpack=buttonId,backpackId
  state.equip,state.consumables=equipId,consumablesId
  state.syncIndicators,state.revision=syncIndicators,revision
end)
if not ok then return "partial: "..tostring(err) end
return status()