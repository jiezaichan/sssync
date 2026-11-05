# sssync 项目规则

两台 Mac（家里 / 公司）的手动同步器，Swift + SwiftUI，只支持 macOS。设计以 `docs/DESIGN.md` 为准，改架构先改文档。

## 核心约束（改代码前必读）

- **每台只改自己**：任何写操作只发生在本机。对面要改的一律写成中转站里的待办（`decisions/<目标机器>/`），由对面的 sssync 自己执行。禁止经 ssh 远程执行写操作或远程拉起进程。
- **冲突永远由用户拍板**：禁止按修改时间判断、禁止「新的赢」、禁止自动选边。
- **待办带前置条件**：目标机器当前值 ≠ `expect` 就作废，不覆盖。
- **先备份再写**：所有覆盖 / 删除先 `Backup.save`，写入后重新扫描校验指纹。
- **基线只存在中转站**（`base/`），两边一致时才更新。
- **对比（diff）自己写**：`Sources/SyncKit/TextDiff.swift`，不引入第三方 diff 库，也不调用外部编辑器做对比。
- **读不到 ≠ 不存在**：某台读不到的东西（沙盒被挡等）整个不参与对比，绝不当成「没有」发待办。
- **环境与应用只改本机**：本机缺的可以补齐 / 升级，本机多出来（对面没有）的可以卸载；卸载要先弹确认，App 不是 brew 装的就移到废纸篓。不提供改对面的按钮，对面的只给复制命令。
- **噪音规则内置在代码里**（`SharedConfig.builtinNoiseKeys`、`Recorder.noisePaths`），`shared.json` 只放用户自己加的，这样改规则不用迁移中转站上的清单。
- 同步清单（`SharedConfig`）两台共用，以中转站 `shared.json` 为准；本机配置（`Config`）只有机器、中转站、常驻选项。新增字段一律 `decodeIfPresent` 给默认值。
- 界面文字全部中文；机器在界面上一律用 `badge`（emoji + 名字），左右列固定家里在左、公司在右（`Snapshot.machineOrder`）。

## 构建与验证

- 工程由 XcodeGen 生成：改 `project.yml` 或增删文件后先 `xcodegen generate`；`sssync.xcodeproj` 不手改。
- 改完必须自己编译并跑测试：

  ```bash
  cd ~/Documents/fullstack/sssync
  xcodegen generate -q
  xcodebuild test -project sssync.xcodeproj -scheme sssync -derivedDataPath build
  ```

- 装到两台：根目录 `./install.sh`（转调 `scripts/install.sh`，只装本机加 `--local`），装到两台的 `/Applications`。脚本会校验签名团队是 96BTTXKZ9W。
- 签名：`Apple Development` + 团队 `96BTTXKZ9W`（见 `project.yml`），不要改回 ad-hoc——签名身份变了，系统授权（完全磁盘访问等）要重新给。

## 环境

- 中转站：`new:~/sssync-relay`（Linux，GNU rsync）。本机一律用 `/usr/bin/ssh`、`/usr/bin/rsync`（openrsync），参数只用两边都支持的：`-a`、`-r`、`--ignore-existing`、`--files-from`、`--delete`。
- 两台：家里 `hw.model = Mac14,5`（`ssh mini` 连公司），公司 `Mac18,5`（`ssh home` 连家里，经反向隧道，家里合盖时连不上）。
- 本机数据：`~/Library/Application Support/sssync/`（`config.json`、`blobs/`、`backups/`）。

## 目录

- `Sources/SyncKit/`：`Engine`（编排）、`Reconciler`（三方对账）、`FileProvider` / `HandlerProvider` / `PrefProvider` / `AgentProvider`（扫描与应用）、`Relay`（中转站）、`TextDiff`（Myers diff）、`Merge`（diff3）、`Report` + `EnvCompare`（环境与应用报告）、`Recorder`（录制）、`Secrets`（打码）、`CommandRunner`（本机补齐命令）
- `Sources/App/`：`AppModel`、`ContentView`（列表）、`EnvView`（环境 / 应用 / 命令面板）、`DiffView`（对比窗口）、`Sheets`（合并、模板、录制）、`SettingsView`（通用 + 同步清单）、`SssyncApp`（窗口 + 菜单栏）
- `scripts/`：`install.sh`、`make-icon.swift`
