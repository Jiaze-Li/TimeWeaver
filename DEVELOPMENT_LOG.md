# TimeWeaver 开发日志 / 项目经理交接文档

最后更新：2026-03-09  
当前项目目录：[PPMSCalendarSync](/Users/jack/PPMSCalendarSync)  
当前桌面成品：[TimeWeaver.app](/Users/jack/Desktop/TimeWeaver.app)  
当前仓库默认构建产物：[TimeWeaver.app](/Users/jack/PPMSCalendarSync/build/TimeWeaver.app)

## 1. 先给下一个 PM 的一句话结论

这是一个已经从“PPMS 专用同步工具”演进为“通用 sheet / timetable / image -> Apple Calendar 导入与同步桌面应用”的项目。  
当前产品名是 `TimeWeaver`，但为了不打断现有用户数据迁移，很多底层存储名字仍然沿用 `PPMSCalendarSync`。

接手这个项目时，最重要的不是继续堆功能，而是同时守住这三条：

- 客户第一次打开就能理解怎么用
- 页面信息密度高，但不能重叠、不能乱
- 每次交付前都要真实 build 和真实测试，不接受“只改代码没验证”

## 2. 当前产品定位

当前定位已经明确不是：

- 不是一个实验室内部临时脚本
- 不是一个只会读固定 PPMS 表格的同步器
- 不是一个只靠工程师自己看懂的后台面板

当前定位是：

- 通用的时间表导入与同步 macOS app
- 支持公开 sheet、本地 `.xlsx`、结构化 timetable 图片
- 支持本地解析、规则解析、AI 解析三层组合
- 客户可用，未来可对外发布到 GitHub / DMG 下载

## 3. 用户画像与合作偏好

这一节非常重要。下一个项目经理如果不读，很容易重复犯错。

### 3.1 用户对工作方式的偏好

- 用户希望你像“项目经理 + 设计负责人 + QA”一起工作，不接受“你说一句我动一下”的被动式开发
- 用户会直接指出你没有主动思考，这不是情绪问题，而是明确的协作要求
- 用户非常重视你是否真实测试过，而不是只说“理论上没问题”
- 用户不喜欢代码式解释，很多时候需要先翻译成人话
- 用户会要求你把上下文和项目记录整理好，方便下一任无缝接手

### 3.2 用户对 UI 的稳定偏好

- 强烈反感大块无意义空白
- 喜欢高信息密度，但不是小字体堆满屏
- 明确要求“box 不要太大，但是信息要明显”
- 不喜欢看起来像后台临时表单的布局
- 不喜欢主路径藏在 toolbar 或纯图标入口
- 只要是客户会看到的内容，就要用客户语言，不要把 parser 内部日志直接扔到前端
- 对重叠、压缩、突兀换行、滚动异常都非常敏感

### 3.3 用户对交付方式的偏好

- 任何视觉或交互修改后，最好直接 build 到桌面成品给用户点开看
- 老包和新包不要同时留在桌面上
- 发布物要方便客户下载，优先提供 `.dmg`

## 4. 产品方向演进历史

### 阶段 A：PPMS 专用同步器

最早目标是：

- 读取 PPMS 风格的 Google Sheets
- 用 booking ID 匹配固定时段
- 写进 Apple Calendar

这个阶段的核心问题：

- 产品名太具体，局限在 PPMS
- slot-based 规则过于依赖单一表格版式
- UI 更像工程内部工具，不像对外产品

### 阶段 B：原生 macOS 工具化

做过的事：

- 放弃 Python GUI 壳，转为原生 SwiftUI + EventKit
- 引入多 source
- 引入 Preview / Sync
- 引入日历选择

这个阶段暴露的问题：

- 布局不稳
- 高空白
- 某些区域被垂直拉伸
- 滚动和嵌套滚动体验差

### 阶段 C：产品化与高密度重构

做过的事：

- 主路径从隐藏式操作改为正文显式 `New / Save / Remove / Preview / Sync / Calendar`
- 左右双列布局稳定化
- Output 改成 `Activity`
- 支持 `Source` 列表、状态、输出、Automation、AI Parsing
- 大量收紧 spacing、空白、按钮布局

### 阶段 D：通用解析能力扩展

做过的事：

- 从固定 sheet 规则扩展到 AI provider
- 加入 OpenAI / Gemini / Anthropic / Kimi / DeepSeek / Custom provider 预案
- 增加图片导入
- 对结构化 timetable 图片加入本地解析器，使部分图片不依赖 API

### 阶段 E：客户交付与发布准备

正在做 / 已做：

- 产品重命名为 `TimeWeaver`
- DMG 打包
- GitHub 发布准备
- 全量交接文档

## 5. 当前功能事实，以现在代码为准

### 5.1 Source 与导入

- 支持多个 saved source
- 每个 source 可包含：
  - source 链接或本地路径
  - booking ID
  - event title
  - calendar
  - enabled / use in sync
- 支持 drag-and-drop 图片即时导入
- 图片导入不会覆盖 saved sheet source；这是独立的一次性导入流

### 5.2 解析策略

当前不是单一路径，而是多层解析：

- 规则解析器：适合固定 workbook 结构
- 本地 timetable 图片解析器：适合彩色结构化课表图
- AI parser：适合作为通用兜底和特殊版式处理

### 5.3 AI 平台现状

当前内置 provider：

- OpenAI
- Gemini
- Anthropic / Claude
- Kimi
- DeepSeek
- Custom

当前真实产品结论：

- 结构化 timetable 图片，优先走本地解析器
- 复杂图片里，Gemini 当前最稳
- DeepSeek 在本项目中按 text only 处理
- 客户不应被要求自己理解 endpoint；支持的平台应自动填 endpoint 和推荐 model
- endpoint 输入仍然必须保留给自定义平台 / 代理 / 网关

### 5.4 Calendar 行为

当前不是“只增不删”的旧策略了。当前产品支持：

- 新增
- 更新
- 删除此前由本 app 创建、且源里已经消失的事件

但删除现在是可控的：

- `Show confirmation before sync`
- `Ask before deleting removed events`

Sync 前会弹确认，展示本次 `Add / Update / Remove` 数量。

### 5.5 时间策略

早期 `Slot Times` 已被产品上放弃。当前策略是：

- sheet 里有明确时间，直接用 sheet 时间
- sheet 里只有日期没时间，使用 `Default Work Hours`
- 当前默认工作时间是产品字段，不再要求用户维护一堆 slot label 映射

## 6. 当前 UI 架构

### 6.1 主窗口

当前主窗口结构：

- 顶部：标题、状态、统计卡
- 中部：Quick Actions
- 下部：左右双列
  - 左：`Sources + Activity`
  - 右：`Source Details / AI Parsing / Default Work Hours / Automation`

### 6.2 当前布局状态

当前主列不是固定死的 `HStack`，已经改为可拖动的 `HSplitView`。这意味着：

- 用户可以手动拖动左右列宽度
- 左栏不是写死宽度
- 这对客户很重要，因为不同人关注 `Sources` / `Activity` 的权重不同

### 6.3 当前窗口尺寸事实

代码里的显式窗口底线已经多次下调。当前真实测得结果是：

- 实际最小宽度约 `640`
- 实际最小高度约 `652`

说明：

- 代码中显式 `minHeight` 已经比 652 更低
- 652 是当前内容自然尺寸造成的真实下限
- 如果还要继续压高度，要继续收顶部区、Quick Actions 和右侧 pane 的自然高度

## 7. 用户明确表达过的设计原则

这部分应视为产品约束。

### 7.1 信息密度原则

- 不要让 box 比内容大太多
- 不要为了“紧凑”把信息一起缩没
- 允许 box 变小，但信息本身要明显
- 用户多次明确表示：空白应减少，但标签和数字应清晰

### 7.2 交互路径原则

- 所有高频主操作应显式出现在正文
- 不要藏在二级菜单或需要猜的入口里
- 图片导入要即时反馈，而不是让用户先把 source 配置污染掉

### 7.3 语言原则

- 客户前端看到的是产品语言
- 纯技术日志不要直接显示
- 像 `Parser note` 这种工程话术应避免出现在客户 UI

### 7.4 解释原则

- 用户经常会要求“用能听懂的话讲”
- 如果用户问“为什么不能再缩”，优先解释是哪个界面区域会先出问题，而不是先甩代码片段

## 8. 真实开发记录摘要

以下是关键变更，不是所有 commit 的逐字抄录，而是产品/技术上的关键节点。

### 8.1 布局和滚动

- 修过多轮 section 被异常撑高的问题
- 去掉过会导致不稳定高度计算的布局方案
- Output 由可编辑滚动组件改成客户可读 Activity
- 调整了 Activity 的 placeholder，使权限提示居中显示

### 8.2 交互和可用性

- `New` 做成真正清空草稿并有反馈
- `Browse` 变成完整按钮，不再压坏
- 输入框失焦行为做了统一处理
- 图片支持拖拽导入

### 8.3 同步安全

- Preview 与 Sync 已明确分离
- Sync 前可以展示变更摘要
- 删除操作增加显式确认策略

### 8.4 AI 相关

- 平台预设与自动 endpoint/model
- 本地 timetable parser 先行，AI 作为补充
- 对低置信度 AI 结果增加 review gate
- 对部分 provider 的图片能力做过 live probe

### 8.5 包装与命名

- 产品名从 `PPMS Calendar Sync` 改为 `TimeWeaver`
- 桌面成品已切换为 `TimeWeaver.app`
- 旧存储目录和 Keychain service 暂保留 legacy 名称

## 9. 当前技术细节

### 9.1 技术栈

- Swift
- SwiftUI
- AppKit
- Combine
- EventKit
- Security

### 9.2 代码组织

当前主要逻辑基本集中在：

- [PPMSCalendarSync.swift](/Users/jack/PPMSCalendarSync/PPMSCalendarSync.swift)

辅助文件：

- [Info.plist](/Users/jack/PPMSCalendarSync/Info.plist)
- [build_native_app.sh](/Users/jack/PPMSCalendarSync/build_native_app.sh)
- [README.md](/Users/jack/PPMSCalendarSync/README.md)
- [DEVELOPMENT_LOG.md](/Users/jack/PPMSCalendarSync/DEVELOPMENT_LOG.md)

### 9.3 数据与迁移

当前仍沿用以下 legacy 标识，原因是避免升级后丢设置：

- Application Support: `~/Library/Application Support/PPMSCalendarSync`
- Keychain service: `PPMSCalendarSync`

不要轻易改掉，除非你同时写好迁移。

## 10. 测试与验证习惯

用户对“你是否真的测试过”非常在意。当前推荐的最低交付标准：

- 代码改完后必须 build
- 要把产物同步到桌面 app
- 关键交互要做至少一轮真实运行验证
- 宽度 / 高度 / 滚动 / 按钮响应，不能只靠脑补

典型验证方式：

- 本地 build：`build_native_app.sh`
- 同步桌面包
- 启动桌面 app
- 必要时用 AppleScript / System Events 检查窗口尺寸或响应

## 11. 已知风险与未完成事项

### 11.1 当前已知风险

- 虽然最小高度已下调，但真实最小高度仍受内容自然尺寸影响
- 右侧各 pane 仍可继续做纵向紧凑化
- AI 结果在复杂非结构化图片上仍不能完全替代 review
- 当前项目以单文件 Swift 源为主，继续扩展时维护成本会上升

### 11.2 下一步高价值方向

- 继续压缩右侧 pane 的自然高度
- 继续整理 AI provider 抽象，避免主文件继续膨胀
- 增加发布自动化，包括 DMG 和 GitHub Release 流程
- 如需对外分发，补充签名 / notarization / license

## 12. 发布现状

当前 GitHub 侧事实：

- 本地 git 仓库存在
- 之前没有配置 remote
- 当前机器上的 GitHub 账号已登录，可用于发布

当前发布目标：

- 代码推送到 GitHub
- 至少提供 `TimeWeaver.dmg` 作为客户下载物

## 13. 对下一任 PM 的直接建议

如果你继续这个项目，请遵循下面这些做法：

- 不要先堆新功能，再等用户指出 UI 坏了
- 不要只看代码逻辑，一定要打开桌面 app 看真实效果
- 不要默认用户想听技术词汇，先讲产品层面的原因
- 不要轻易回退到“只支持固定表格版式”的旧思路
- 所有“客户可见文字”都按产品语言处理
- 继续保持“先本地稳定解析，再用 AI 补充”的路线

## 14. 本次交接时的关键文件和产物

- 源码：[PPMSCalendarSync.swift](/Users/jack/PPMSCalendarSync/PPMSCalendarSync.swift)
- 本地构建脚本：[build_native_app.sh](/Users/jack/PPMSCalendarSync/build_native_app.sh)
- DMG 脚本：`create_dmg.sh`（若不存在，需补）
- 当前 build app：[TimeWeaver.app](/Users/jack/PPMSCalendarSync/build/TimeWeaver.app)
- 当前桌面 app：[TimeWeaver.app](/Users/jack/Desktop/TimeWeaver.app)

## 15. 最后一条提醒

用户不是在要一个“看起来差不多能用”的 demo，而是在要一个别人也可以下载、理解、运行、信任的产品。  
接手后请继续保持 PM 视角、设计视角和 QA 视角一起工作，而不是只做代码搬运。

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

## 13. 2026-03-09 解析误读与未来过滤修复

### 13.1 用户反馈

用户指出：

- `PLD` 没有同步 `2026-03-09`
- `ppms` 和 `ppms-2` 却同步出了 `2026-03-10 08:30-13:00` 与 `2026-03-11 08:30-13:00`
- 但用户确认原始 `ppms` sheet 里并没有这两天的 `LJZ`

### 13.2 实际排查结果

先确认 source 配置与同步状态：

- `settings.json` 中 `upcomingOnly = true`
- `sync-state.json` 中确实记录了：
  - `ppms` 的 `2026-03-10 08:30-13:00`
  - `ppms` 的 `2026-03-11 08:30-13:00`
  - `ppms-2` 同样两条

再直接下载两份工作簿导出：

- `ppms`: `1J7XCLh20n1qBkhBNyfF0XwnM2vItuOlGl6j5iQR1aVg`
- `ppms-2`: `1iNjlrtNATd7cAi_6ZfSrsWWcTtSa7trjU8OaQCoJfPo`

查 `Mar 2026` 原表后，事实是：

- `LJZ` 真正在 `2026-03-04`、`2026-03-05`
- 以及 `2026-03-17`、`2026-03-18`
- 不在 `2026-03-10`、`2026-03-11`

也就是说，问题不是用户记错，也不是 sheet 临时变了，确实是解析器误读。

### 13.3 根因

根因在 `matchingSlotRows`：

- 旧逻辑会在“日期行”下面继续往下扫最多 6 行
- 只要后面再次遇到 slot label，就继续算作同一组 slot rows
- 在 `ppms` 这种周块布局里，这会把下一周的 slot 行错误挂到上一周的日期头下

具体后果：

- `Mar 2026` 第 2 周的日期头里有 `10 / 11`
- 第 3 周的 slot 行里有 `LJZ`
- 旧代码把这两部分错误拼接
- 于是 `3/17、3/18` 被误读成了 `3/10、3/11`

### 13.4 修复

修复点有两处：

1. `matchingSlotRows` 只接受“紧跟在日期头下面连续出现”的 slot rows  
   一旦已经读到 slot row，再遇到非 slot 行就立刻停止，不再跨周串读。

2. `upcomingOnly` 的过滤语义改严  
   旧逻辑是“还没结束就算 upcoming”  
   新逻辑是“从明天零点开始才算 future”

这符合用户后来明确提出的要求：

- 只对未来 event 作变动
- 今天的 event 不新增、不更新、不删除

UI 文案也同步从：

- `Only upcoming reservations`

改成：

- `Only future reservations`

### 13.5 修复后验证

用当前源码重新编译 `PPMS_TEST_RUNNER` 后，`ppms` 与 `ppms-2` 的 `2026-03` 匹配结果变成：

- `2026-03-04 08:30 -> 2026-03-06 08:30`
- `2026-03-17 08:30 -> 2026-03-19 08:30`

错误的：

- `2026-03-10 08:30 -> 2026-03-10 13:00`
- `2026-03-11 08:30 -> 2026-03-11 13:00`

已经不再出现。

### 13.6 给下一任项目经理的提醒

以后凡是用户说“表里根本没有这条，但软件读出来了”，不要先怀疑：

- 用户看错
- Google Sheets 没刷新
- sync-state 残留

应优先检查：

- 周块式表格是否存在“跨周串读”
- slot row 扫描是否跨过空白或下一组 header
- 日期头与 slot 行是否真的是同一周块

这类 bug 的本质不是 AI，也不是 Calendar，而是**本地规则解析器的分块边界判断**。
