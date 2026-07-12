# Relay 技术设计与数据协议

## 1. 设计目标

Relay 只保存完成一次人类上下文切换所需的信息：

- `focus`：我在做什么；
- `details`：可以逐条添加的具体展开；
- `workspace`：关联 APP 与补充备注；
- 当前选中的上下文、归档时间和更新时间。

“状态”不属于数据模型。是否等待、阻塞或继续，由人根据现场决定；Relay 只负责保存现场和切换现场。

数据默认只存在本机。后续增加 AI 完成提醒、多端同步和窗口感知时，使用版本迁移与扩展字段演进，不复用或改变现有字段的含义。

## 2. 当前架构

```text
SwiftUI View
    │
    ├── ContextStore ─────────── 上下文编辑、切换、归档
    └── ApplicationUsageStore ─ APP 发现与切换频率
                │
                ▼
        RelayPersistence
                │ 原子写入
                ▼
~/Library/Application Support/Relay/relay.json
```

- UI 层不直接读写文件；
- Store 只处理业务状态；
- `RelayPersistence` 统一编码、迁移和落盘，避免不同功能各自维护一份存储；
- 日期统一使用 ISO 8601，标识符使用稳定 UUID 或 APP Bundle Identifier。

## 3. 数据文件

正式 Schema 位于 [`relay.schema.v1.json`](relay.schema.v1.json)，示例位于 [`relay.example.v1.json`](relay.example.v1.json)。当前协议版本为 `schemaVersion: 1`。

顶层是版本化文档，而不是上下文数组：

```json
{
  "schemaVersion": 1,
  "documentID": "A73E827E-7E69-49E5-8533-E1A38B11AA01",
  "applicationVersion": "0.3.0",
  "createdAt": "2026-07-13T08:00:00Z",
  "updatedAt": "2026-07-13T08:05:00Z",
  "activeContextID": "887D4E4E-B065-42E9-9079-E1A38B11AA02",
  "contexts": [],
  "usage": { "applications": [] },
  "extensions": {}
}
```

关键约束：

- `schemaVersion` 决定如何解释整份文件；`applicationVersion` 只记录最后写入它的客户端版本，不能代替协议版本；
- `details` 使用带 UUID 的对象数组，而不是字符串数组，后续可以给单项增加来源、完成提醒或排序信息；
- `workspace.applications` 保存 Bundle Identifier、显示名和路径。Bundle Identifier 是首选身份，路径是缺少 Bundle Identifier 时的回退；
- `archivedAt` 不存在表示未归档，存在则记录归档时间；
- `extensions` 只存不属于稳定核心协议的附加数据。扩展键应使用命名空间，如 `io.eastonsuo.relay.window-context`，防止命名冲突。

## 4. 兼容与迁移

### v0.2.0 → schema v1

首次启动 v0.3.0 时，若 JSON 文件尚不存在，Relay 读取旧版 UserDefaults：

- `title` → `focus`；
- 非空 `content` → 一个 `details` 项；
- `apps` → `workspace.applications`；
- `address` → `workspace.note`；
- `archived: true` → `archivedAt`；
- 旧 `status` 被有意丢弃。

迁移成功后写入 `relay.json`，并记录 `migratedFrom: "userDefaults-v1"`。旧 UserDefaults 暂不删除，作为回退副本。

### 后续版本

每次协议变化只允许按版本逐级迁移：

```text
读取 schemaVersion
    ├── 等于当前版本：解码
    ├── 低于当前版本：依次执行 vN → vN+1，再原子写回
    └── 高于当前版本：只读保护，不覆盖文件
```

迁移规则必须满足：

1. 已有字段的语义不变；需要新语义时新增字段；
2. 不可逆转换前保留原始值，必要时放入带命名空间的 `extensions`；
3. 每一步迁移都有固定输入、固定输出和独立测试；
4. 迁移完成后才替换原文件。

当前实现遇到损坏文件或更高版本 Schema 时会停止写入，避免旧客户端覆盖新数据。

## 5. 写入与数据安全

- 编辑、切换、归档或 APP 使用统计先立即更新内存，200ms 内的连续变化合并为一次文件写入，避免阻塞 Tab 切换；
- 应用退出前强制刷新尚未落盘的数据；
- 使用原子写入：新内容成功落盘后才替换旧文件；
- JSON 使用排序键和缩进，方便人工检查与版本诊断；
- Relay 不读取窗口文本、不截图、不上传 APP 切换记录；
- 重装应用不会删除 `Application Support/Relay/relay.json`。只有用户主动删除该目录或清理应用数据时，数据才会消失。

## 6. 验证清单

- 从 v0.2.0 升级后，原目标、内容、地址、关联 APP 和归档项仍可见；
- 旧状态不出现在新 JSON 中；
- 新增、删除、重排具体展开项后 UUID 保持稳定；
- 关闭并重新打开 Relay 后，活动上下文和全部内容一致；
- 用高于当前版本的 `schemaVersion` 启动时，原文件字节不被改写；
- 写入中断时，原文件仍可解码。
