# HSR EquipBar Toggle

当前版本：**v1.1.0**（源码分支；最新发布仍为 v1.0.3） · [下载 v1.0.3](https://github.com/wdho/HSR-EquipBar-Toggle/releases/tag/v1.0.3) · [使用说明](使用说明.md) · [更新记录](CHANGELOG.md)

《崩坏：星穹铁道》货币战争（GridFight）备战界面的装备栏收纳按钮。

目前仅支持 Windows；考虑到 Android 端的接入门槛（如 root）及维护成本，暂不计划开发 Android 版。

装备多了会向下延伸挡住晶球等 UI。这个 mod 在右上角加一个小按钮，点一下把整块装备栏收起来，再点一下展开；按钮可拖动，位置自动记住。

v1.0.3 起还支持**同款装备自动合并**：一模一样的装备只占一个格子，右下角角标显示数量。

## 用法

| 操作 | 行为 |
|---|---|
| **左键单击** | 装备栏（`EquipList`）隐藏 / 恢复 |
| **右键单击** | 道具栏（`ConsumableList`）隐藏 / 恢复 |
| **左键按住拖动** | 按钮跟手移动，限制在界面内 |
| 松手 | 位置存入 PlayerPrefs，下次进游戏保持 |

按钮上有两条指示条，分别表示装备栏和道具栏当前是否显示。

**装备合并**：同款装备（按原生 `UniqueID` 与 `EquipItemConfig` 属性判等）合并成一个格子，角标显示数量。**开始拖动任意物品时，每组会临时展开到 2 个**，方便你把一件拖到另一件上合成进阶装备，或贴特权卡；松手后自动恢复合并。

按钮默认在右上角。收起是整块显隐，不是把高度压小，格子不会被切到一半。

## 安装

1. 关闭游戏，从 [Releases](https://github.com/wdho/HSR-EquipBar-Toggle/releases) 下载并解压完整 ZIP，再备份 `<游戏目录>\StarRail_Data\Plugins\x86_64\xluau.dll`
2. 把它**复制**一份到游戏根目录，改名 `xluau_real.dll`（原文件保持不动）
3. 把 ZIP 里的 `xluau.dll` 放到游戏根目录（与 `StarRail.exe` 同级）
4. 把 `EquipBarScript.lua` 放到游戏根目录
5. 启动游戏，进入货币战争备战界面

如果根目录已经有其它 mod 的 `xluau.dll`，不要直接覆盖。游戏更新后先关闭游戏并暂时移走本项目的代理 DLL，确认发布说明支持所用客户端版本，再从更新后的 `Plugins\x86_64` 重新复制 `xluau_real.dll`。不要沿用旧原版副本；原版 DLL 不随本项目分发。

```
<游戏目录>
├─ StarRail.exe
├─ xluau.dll              ← 代理，新放入
├─ xluau_real.dll         ← 原版副本，新放入
├─ EquipBarScript.lua     ← 按钮脚本，新放入
├─ EquipBarNative.log     ← 运行日志，自动生成
└─ StarRail_Data\Plugins\x86_64\xluau.dll   ← 原版，始终不改
```

## 卸载

**先关闭游戏**，再删除游戏根目录下的这 4 个文件：

```
xluau.dll
xluau_real.dll
EquipBarScript.lua
EquipBarNative.log
```

`StarRail_Data\Plugins\x86_64\xluau.dll` 从安装到卸载都不会被修改，不需要恢复。

## 热重载

修改 `EquipBarScript.lua` 后以 UTF-8（无 BOM）保存。后台约每 2 秒检查文件，实际执行等游戏下一次进入 Lua 调用；文件上限 256 KiB。同一页面上的回调会按新脚本重新绑定，不会重置装备栏显隐或按钮位置。日志见 `<游戏目录>\EquipBarNative.log`，脚本返回值打印为 `lua => ...`。

## 按钮没出现

确认在货币战争备战界面。其它界面脚本返回 `idle`，本来就不建按钮。

看日志确认 mod 是否加载：正常应有 `hook OK:` 和 `api:` 两行。没有日志时，检查 DLL 是否位于 `StarRail.exe` 同级、根目录是否可写。报告问题时请附游戏版本、区服和相关日志。

## 构建

需要 Windows x64 MinGW-w64（例如 w64devkit）及同工具链的 `objdump.exe`。把工具链的 `bin` 加入 PATH 后运行：

```powershell
.\build.ps1
# 也可直接指定编译器，不必修改脚本
.\build.ps1 -Gcc 'C:\tools\w64devkit\bin\gcc.exe'
.\package.ps1 -Gcc 'C:\tools\w64devkit\bin\gcc.exe'
```

`build.ps1` 生成 `out\xluau.dll`，逐项核对 218 个公开函数到 `xluau_real.dll` 的转发映射。`package.ps1` 重新构建后生成 `out\HSR-EquipBar-Toggle.zip`，包含 DLL、Lua、使用说明、更新记录和 MIT 许可证。

离线 Lua 测试（不启动游戏）：`lua tests/equipbar-regression.lua`（Lua 5.4）。

## 实现要点

游戏用相对路径 `LoadLibrary("xluau.dll")` 加载 Lua 运行时，exe 同目录优先命中。代理 DLL 转发 218 个导出到 `xluau_real.dll`，并在真身的 `lua_pcall` 入口下 5 字节 inline hook 取得 `lua_State*`。

`lua_pcall` 是游戏调用 Lua 函数的必经入口，而 Lua state 不是线程安全的，所以脚本必须在这个 hook 里执行，不能从独立线程调用。

折叠只切换 `EquipList` / `ConsumableList` 的 `activeSelf`，不改动布局尺寸和间距。初始化时会把 `Content` 的锚点校正为右上（兼容早期两列布局留下的左侧锚定），之后不再触碰任何布局参数。

**堆叠识别不依赖图标名**：从 `RPG.Client.GlobalVars.s_UIManager` 取 `GridFightPreparationPage`，读 `_binder.panel_equip_item_pack._equip_items` 的原生数据，逐项校验 `UniqueID` 与槽位绑定，再按 `EquipItemConfig` 的类别、属性列表、Frame、来源类型和售价判等。

**角标是独立图层**：`WDHO_StackBadgeLayer` 挂在 `EquipList/ScrollView/Viewport` 上，用 7 段数码管自绘数字，**完全不修改游戏原生的 `NumText`**。这是为了让对象池复用格子时不会带着外部写入的文字状态，从而彻底避免"数字串到下一件装备"。

**合并时隐藏的是 Slot**（`Content` 的直接子节点），不是 icon 的 `Root`，并调用 `LayoutRebuilder.ForceRebuildLayoutImmediate` 让网格立即收拢，否则会留下空格。

查找节点用 `Transform.Find` 而非 `GameObject.Find`——后者不搜索未激活对象，装备栏一旦隐藏就再也找不到。

## 已知限制

- 图标用两个旋转的 Image 拼成箭头：这个 IL2CPP 构建里 `UI.Text.AddComponent` 会静默失败
- `mhypbase` 拦截 `SendInput`，模拟输入驱动不了游戏，按钮必须真人点击
- `Camera.main` 为 null（Overlay canvas），坐标按 `canvas.scaleFactor` 换算
- hook 以 `lua_pcall` 导出地址为准，并用 5 字节序言校验；游戏版本更新后需重新确认
- 特权卡（`Emblem` 类别）不参与合并判等，只按原样显示
- 拖拽时每组固定展开 2 个，如果某组超过 2 件，第三件起仍在拖拽期间保持隐藏

## 风险提示

本项目会加载代理 DLL 并修改客户端内存中的 Lua 调用入口。实测可用不代表官方许可、未来版本兼容或账号安全；本项目不提供反作弊规避或相关保证。

## 声明

- 作者与维护者：**wdho**。本次稳定性审查、修复、测试脚本和文档整理使用了 **OpenAI Codex 辅助**；游戏内拖拽与点按由作者实际操作确认。
- 本项目是非官方社区工具，与米哈游 / HoYoverse 无隶属、合作或背书关系。相关游戏、商标与原版文件归各自权利人所有。
- 本仓库原创代码按 [MIT](LICENSE) 许可发布；该许可不涵盖游戏本体或原版 DLL。分发本项目时请保留许可证与版权声明。
- 实测记录：2026-11-16，Windows x64，本机启动器配置 `game_version=4.7.0`、`hkrpg_cn`、`channel=1`。新版 DLL 启动、备战页按钮、作者确认的拖拽/点按及同进程 Lua 热重载通过；Unity 桥接未就绪的等待分支通过离线回归，补丁热加载后未额外重启验证。
- 结果仅代表上述环境和项目，不承诺全版本、全分辨率或其它 mod 组合均兼容。