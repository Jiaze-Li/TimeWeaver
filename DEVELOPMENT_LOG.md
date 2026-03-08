# PPMS Calendar Sync 开发日志 / 项目交接文档

最后更新：2026-03-08  
当前项目目录：[PPMSCalendarSync](/Users/jack/PPMSCalendarSync)  
当前桌面成品：[PPMS Calendar Sync.app](/Users/jack/Desktop/PPMS%20Calendar%20Sync.app)

## 1. 项目目标

本项目的目标不是做一个一次性脚本，而是做一个**可长期维护、可发布、可交接的 macOS 原生应用**。核心业务是：

- 读取一个或多个 Google Sheets / 本地 `.xlsx` 预约表
- 根据用户配置的 `booking ID`
- 解析月度分页中的预约时间段
- 同步到用户指定的 Apple Calendar

用户明确要求这个产品最终应满足以下定位：

- 是一个**完整 app**，不是脚本壳或临时工具
- 后续可以发布到 GitHub 给其他人使用
- 支持多个 sheet source
- 支持自动检查更新并同步
- 删除行为必须极其保守
- UI 不能像工程临时面板，必须有合理的交互逻辑

## 2. 用户明确提出过的关键要求

以下是用户在开发过程中明确表达过、且对后续接手人仍然有效的要求。它们应视为产品约束，而不是可随意改动的建议。

### 2.1 功能约束

- 支持多个 source，而不是只支持一个 sheet link
- 每个 source 至少包含：
  - sheet link 或本地 workbook 路径
  - booking ID
  - event title
  - target calendar
- 预约事件标题应与来源 sheet 名 / source 名一致，例如 `ppms`
- 备注里尽量简洁，只保留 `sheet link`
- 用户要能自定义 time slot 的起止时间

### 2.2 Apple Calendar 相关约束

- 默认同步到 `Experiment` 日历
- 允许选择别的 calendar
- **绝不自动删除** Calendar 事件
- 如果 sheet 里某条预约消失，只能提示为 manual delete candidate，不能自动删
- 更新只允许作用于本 app 自己创建和标记过的事件

### 2.3 自动化约束

- 支持自动轮询同步
- 当前实现是“app 打开时后台轮询”
- 用户未来可能希望更强的自动化，但当前版本先不做后台守护进程

### 2.4 UI / 产品要求

用户对交互设计非常敏感，而且要求非常明确：

- 不要把明显低效的排版留到用户指出后才修
- 不要把主路径藏在右上角图标里
- 新用户第一次打开 app，就应该知道怎么用
- 页面应尽量紧凑，提高单位面积的信息密度
- 在不重叠的前提下，**优先使用双列**提升效率
- 按钮和信息区不应出现无意义的大空白
- 任何窗口尺寸下都不应该出现文字或按钮重叠

## 3. 产品经理视角下的核心设计原则

本项目的产品方向已经从“功能能跑通”转向“别人第一次打开也能理解并使用”。接手人应继续坚持以下原则：

### 3.1 主路径显式化

用户已经明确否定过这些设计：

- 把主操作藏在 toolbar 右上角
- 把高频按钮做成只靠图标理解的入口
- 让用户自己猜顺序

因此当前主路径必须保持为正文中可见的显式动作：

- `New`
- `Save`
- `Remove`
- `Preview`
- `Sync`
- `Calendar`

### 3.2 双列优先，但不能牺牲稳定性

用户希望页面更高效，`Sources` 不应占太宽，因此：

- 宽窗口优先用双列
- 左侧 `Sources` 窄栏固定较小宽度
- 右侧为主编辑区
- 窄窗口可退回单列，但不能因为切换导致重叠或闪烁

### 3.3 参数编辑区域应像“工具软件”，不是表单草稿

用户对 `Slot Times` 区域多次提出批评，核心不是单个像素，而是产品感：

- 不要有大块无意义空白
- 不要把高频按钮竖着浪费空间
- 不要让一组参数看起来像还没整理过的后台表单

因此，`Slot Times` 必须继续沿“紧凑、参数表、区头动作栏”的方向优化。

## 4. 当前技术方案

### 4.1 技术栈

- Swift
- SwiftUI
- EventKit
- 原生 macOS app bundle
- `swiftc` 构建

### 4.2 当前项目文件

- [PPMSCalendarSync.swift](/Users/jack/PPMSCalendarSync/PPMSCalendarSync.swift)
- [Info.plist](/Users/jack/PPMSCalendarSync/Info.plist)
- [build_native_app.sh](/Users/jack/PPMSCalendarSync/build_native_app.sh)
- [README.md](/Users/jack/PPMSCalendarSync/README.md)
- [DEVELOPMENT_LOG.md](/Users/jack/PPMSCalendarSync/DEVELOPMENT_LOG.md)

### 4.3 当前构建方式

构建命令：

```bash
/Users/jack/PPMSCalendarSync/build_native_app.sh "/Users/jack/Desktop/PPMS Calendar Sync.app"
```

仓库内默认构建输出：

```bash
/Users/jack/PPMSCalendarSync/build/PPMS Calendar Sync.app
```

## 5. 当前已验证的业务能力

以下能力已经被实际跑通过，不是理论设计：

- 可以读取公开 Google Sheets
- 可以识别月度分页
- 可以解析 `Sun` 到 `Sat` 的日期布局
- 可以识别 `8:30-1pm`、`1pm-6pm`、`overnight`
- 可以根据 booking ID 精确匹配单元格
- 可以把连续 slot 合并成连续 calendar event
- 可以写入 Apple Calendar
- 可以增量更新而不重复创建
- 不会自动删除事件
- 支持多个 source

## 6. 用户提供过的真实业务语境

这不是抽象 demo，而是用户真实实验室预约表场景：

- Google Sheets 是实验设备预约表
- 月份页是按月排的设备预约
- booking ID 例如 `LJZ`
- 目标日历例子：`Experiment`
- 典型来源之一：`ppms`

重要说明：

- 当前用户对“删除”极其敏感
- 当前用户对“空白、重叠、低效排版”极其敏感
- 当前用户期望你像产品负责人一样主动收敛问题，而不是等逐条指出

## 7. 关键产品决策记录

### 7.1 放弃 Python GUI 壳，转为原生 app

最初存在 Python + Tkinter / 打包壳路径，但用户明确认为：

- 启动慢
- 卡
- 不像正式 macOS app

因此项目方向已切换为原生 macOS app。  
旧 Python 过渡版已经清理掉，不应作为主线继续。

### 7.2 删除策略固定为“只提示，不自动执行”

这条已经多次确认，不应回退：

- 自动新增：允许
- 自动更新：允许
- 自动删除：不允许
- 如果某条预约从 sheet 消失：只显示 manual delete candidate

### 7.3 Preview 与 Sync 必须真正分离

早期原型里曾出现过“预览实际上也写入日历”的风险。  
现在的要求是：

- Preview 只展示即将发生的变更
- Sync 才真正写入 Apple Calendar

### 7.4 “0 match” 不能模糊表达

用户曾遇到 `match 0`。真实情况是：

- 可以解析到历史预约
- 但由于默认只同步未来预约
- 所以未来条目为 0

因此产品需要把“总匹配数”和“被未来过滤掉的历史数”表达清楚。

## 8. UI 迭代历史摘要

这部分不是代码历史，而是产品历史。新 PM 接手时需要知道用户为什么会持续打回。

### 阶段 A：临时能用

特征：

- 功能能跑
- 布局粗糙
- 主要目标是验证同步链路

问题：

- 用户不接受“壳产品”
- 启动和交互都不符合正式 app 预期

### 阶段 B：基础原生版

特征：

- 改为原生 macOS app
- 加入多 source、slot time、自定义 calendar

问题：

- 多处重叠
- 布局对窗口尺寸不稳
- 操作路径不清晰

### 阶段 C：重叠修复期

做过的事情：

- 改响应式布局
- 改单双列切换
- 把 output 放入主列

用户反馈：

- 不要只修一处重叠
- 任何尺寸都不能重叠

### 阶段 D：交互路径梳理期

做过的事情：

- 把主路径按钮从隐藏式 toolbar 转为正文显式按钮
- 缩短按钮文案
- 增加主次按钮层级

用户反馈：

- 不要临时堆按钮
- 要像项目经理一样思考布局逻辑

### 阶段 E：密度优化期（当前）

做过的事情：

- 收紧 `Slot Times`
- 行内参数表化
- 卡片式区块替换默认 GroupBox 留白
- 双列偏好布局

当前仍需继续关注：

- 用户依然会对明显空白和低效排布提出更高要求
- 当前界面虽已明显改善，但仍应继续产品化打磨

## 9. Git 历史摘要

当前最近的重要提交：

```text
eed8af1 Replace grouped panels with compact cards
b3ca0ff Reduce slot times vertical padding
cfb86f4 Tighten slot times layout and keep rule actions horizontal
5a03b37 Compact slot rule editing and move actions into section header
a6bf9b6 Refine action hierarchy and compact button labels
101021c Make primary actions explicit in the main window
ecd934a Move frequent actions into the window toolbar
b10e868 Prefer two-column layout on medium widths
755227a Keep output inside main column to avoid overlap
f8cfd05 Restore narrow sidebar layout on wide windows
0a43c95 Use overlap-safe single-column layout
e70af7c Improve responsive window layout
```

这些 commit 反映的不是代码洁癖，而是用户一次次指出的真实产品问题。  
接手人不要把这些迭代理解成“反复横跳”，而应该理解为用户在用非常高的产品标准筛界面。

## 10. 当前存在的风险与未完成项

### 10.1 UI 仍可能继续被要求压缩

虽然已多轮收紧布局，但从用户反馈风格看，以下区域仍可能继续被要求优化：

- section 之间的垂直节奏
- sidebar 宽度
- Quick Actions 的视觉密度
- `Output` 的占位高度
- `Automation` 区的说明文案占位

### 10.2 首次使用引导仍可加强

当前已有主路径按钮和简要提示，但还不是完整 onboarding。  
如果要继续提升“陌生用户第一次打开就懂”，可以考虑：

- 顶部 3 步式流程提示
- 空状态时的例子 source
- 更明确的结果反馈

### 10.3 发布前事项还未完成

如果未来真的准备公开发布，还需要：

- 更稳定的截图和宣传页面
- License 决策
- 签名 / notarization
- 版本号策略
- Release notes

## 11. 下一任项目经理接手建议

### 11.1 先做什么

接手后建议按这个顺序：

1. 先亲自打开桌面成品看当前界面
2. 用真实 source 跑一遍 `Preview`
3. 用用户最敏感的视角检查：
   - 空白是否过多
   - 主路径是否一眼可懂
   - 双列是否真的提高效率
   - 是否还有任何重叠
4. 再决定下一轮 UI 精修，而不是先改技术底层

### 11.2 不要先做什么

短期内不建议优先投入：

- 复杂新功能扩展
- 多账号同步花活
- 菜单栏后台常驻
- 过度美术化皮肤

当前最重要的仍然是：

- 使用效率
- 可理解性
- 紧凑度
- 可靠性

### 11.3 对用户的沟通方式

这个用户已经多次明确表达：

- 不希望自己去教 PM 怎么做产品
- 不希望被要求一步一步指出明显问题
- 更希望你主动发现和消灭低质量设计

因此接手时必须避免：

- “你想让我怎么改？”
- “要不要这样？”
- “如果你愿意我可以……”

更好的方式是：

- 先做出一轮完整判断
- 直接给出成品
- 只在真正不可假设的决策点上才提问

## 12. 当前一句话结论

这个项目已经从“预约脚本”升级成了“可交接、可发布的原生 macOS 工具”，但用户的标准已经明确提升到**产品级体验**。  
下一任项目经理接手时，应把重点继续放在**界面密度、主路径清晰度、双列效率、和保守同步行为**上，而不是回到“先把功能跑通”的思维。
