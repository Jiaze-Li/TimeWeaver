# TimeWeaver 架构与核心流程说明

本文档用于帮助新参与开发的开发者或 Agent 快速理解 TimeWeaver 的核心职责、架构设计、同步数据流以及关键约束。

---

## 一、系统职责

TimeWeaver 是一个专为个人设计的 macOS 菜单栏/窗口日历同步工具。其唯一核心目标是：
**将多源（Google Sheets、本地 `.xlsx`、日程时刻表截图）的预约/排班数据，准确、幂等、无害地同步至 Apple Calendar (EventKit)。**

---

## 二、核心工作流

```
SourceItem (Sheet/File/Image)
       │
       ▼
[ReservationExtractor / AIWorkbookNormalizer / LocalImageParser]
       │
       ▼
ExtractionResult (ReservationEvent 集合)
       │
       ▼
SyncPlan (包含 Sources、UpcomingOnly、Workday 及 Extractions 缓存)
       │
       ▼
[CalendarSyncEngine]
   ├── 身份匹配 (UUID stableIdentity 优先，旧 hash legacyIdentity 回退)
   ├── 人工覆盖 (EventOverride: title, start, end 区间合法性校验)
   ├── 误删除防御 (isDeletionSuspicious: 解析异常或空结果时阻断批量删除)
   └── 变更写入 (Apple Calendar / EventKit 幂等增删改，支持跨日历迁移)
       │
       ▼
SyncState (持久化存储已同步事件指纹，保持幂等与撤销能力)
```

---

## 三、关键模块与职责

1. **`Sources/Models/`**
   - `SourceItem`: 数据源实体。使用 `id: UUID` 作为绝对稳定的身份基准（`stableIdentity`），同时兼容历史的 `legacyIdentity` 哈希计算。
   - `SyncModels`: 定义同步领域对象（`ReservationEvent`, `SyncPlan`, `EventOverride`, `SourceSyncReport`, `ImageImportUndoRecord` 等）。
   - `SyncState`: 本地已同步事件的索引映射（`[syncKey: StoredEvent]`）。

2. **`Sources/TimeWeaverCore/`**
   - 纯逻辑决策模块，零 UI / 零 EventKit 依赖，支持 SPM 原生秒级单元测试。
   - 决策函数：`determineUpsertMutation`, `matchesSourceIdentity`, `isDeletionSuspicious`, `shouldDeleteTrackedEvent`, `validateTimeInterval`。

3. **`Sources/Sync/`**
   - `CalendarSyncEngine`: Actor 隔离的同步执行引擎。
   - `CalendarStoreProtocol`: EventKit 抽象接口，支持生产（`EKEventStore`）与测试 Fake（`FakeCalendarStore`）。
   - `ReservationExtractor`: 表格与数据提取聚合。

4. **`Sources/Parsers/`**
   - `DateTimeParsingUtilities`, `XLSXPackage`, `WorksheetParser`, `XMLWorkbookParsers`: 本地高性能表格解析。
   - `LocalImageParser`: 本地结构化日程图像识别。
   - `AIWorkbookNormalizer`: 大模型解析适配。

5. **`Sources/Storage/` & `Sources/UI/`**
   - `SettingsStore`, `KeychainStore`: 保证历史兼容性（兼容读取 `PPMSCalendarSync` 目录与 Keychain 服务）。
   - `AppModel` & SwiftUI 视图: 状态管理与桌面/状态栏交互。

---

## 四、核心约束与防错准则

1. **身份稳定性 (Source Identity & Event SyncKey)**:
   - Source 身份由 `SourceItem.id` 决定，修改 Source 名称、Booking ID、Target Calendar 绝不应丢失追踪或导致事件重复创建。
   - SyncKey 基于 `sourceID + sheetNames + cellReferences`，不再嵌入易变的 `bookingID`。
2. **预览与执行一致性 (SyncPlan Cache & Invalidation)**:
   - Preview 产生的解析结果保存在 `SyncPlan` 中；用户确认执行时复用该解析结果，杜绝二次解析导致的数据漂移。
   - 任何修改配置、切换 Source、修改工作时间等操作，必须显式调用 `invalidatePendingSyncPlan()`。
3. **删除保护机制**:
   - 当解析结果为 0 且历史存在已同步事件时，触发 `isDeletionSuspicious`，阻止意外清空日历。
4. **人工编辑生效保障**:
   - 图片导入预览界面允许修改事件标题、开始与结束时间。所有修改经 `EventOverride` 传递并在写入 EventKit 时进行严格时间区间合法性校验（`start < end`）。
