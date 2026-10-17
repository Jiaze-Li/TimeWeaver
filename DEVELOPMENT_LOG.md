# TimeWeaver 历史记录与归档说明

> **说明**：Git 已经完整管理修改历史与提交记录。根据项目简化原则，历史开发日志已封存，不再作为持续追加的主要文档。
> 
> 当前系统的架构、同步流程、模块分工与核心约束，请直接查阅 [ARCHITECTURE.md](ARCHITECTURE.md)。
> 项目使用方法与构建测试命令，请参阅 [README.md](README.md)。

---

## 历史演进概要

1. **早期阶段 (PPMSCalendarSync)**：
   - 最早作为实验室 PPMS 预约系统的自动化日历同步工具。
   - 使用固定目录与服务标识存储历史状态及 Keychain 密钥。

2. **中期阶段 (产品泛化与 TimeWeaver 演进)**：
   - 拓展为支持通用 Google Sheets、本地 `.xlsx` 工作簿以及结构化日程课表图片的 macOS 工具。
   - 引入多种 AI 服务提供商（OpenAI, Gemini, Claude, Kimi, DeepSeek）进行自由格式排班表归一化。
   - 建立安全的数据迁移机制（自动从旧 `PPMSCalendarSync` 目录继承历史配置与凭据）。

3. **可靠性与简化治理阶段**：
   - 确立以 `SourceItem.id` 为基准的绝对稳定 Source 身份体系，解耦易变属性与哈希。
   - 彻底解决图片导入时人工调整时间生效写入及区间合法性校验。
   - 建立解析异常与误删除防御屏障，阻断潜在的历史日历清空风险。
   - 引入 `SyncPlan` 缓存机制与全流程失效联动，保证预览变更与实际写入完全一致。
   - 将 SPM 纯逻辑测试与 Fake CalendarStore 集成测试纳入 GitHub Actions CI。
