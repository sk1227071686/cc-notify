# Anthropic Claude CLI Hooks 机制完全使用指南

## 摘要

Claude CLI（命令行界面）是 Anthropic 推出的强大生产力工具，而 Hooks 机制是其区别于传统基于提示词 AI 流的核心工程化能力之一。它允许开发者在 Claude 生命周期的**特定事件节点**挂载自定义脚本，实现对 Claude 行为的**确定性控制**—— 包括执行前的安全拦截、执行后的代码格式化、会话结束后的自动审计等，是将 "建议性规则" 转化为 "强制性铁律" 的关键枢纽[(44)](http://m.toutiao.com/group/7653321298067718671/)。

本文将从架构设计、创建流程、安装配置、调用机制、实战案例五个维度，全面解析 Claude CLI Hooks 的技术细节与使用方法，帮助你在本地开发、CI/CD Pipeline、团队共享工程等场景中，精准扩展 Claude 的能力边界。

## 1. Claude CLI Hooks 机制核心概述

在深入操作指南之前，需要先明确 Hooks 的基本定义、设计理念与关键应用场景，为后续流程化实践建立基础认知。

### 1.1 什么是 Hooks 机制？

Hooks 是挂载在 Claude CLI 生命周期特定事件节点上的**自定义自动化脚本或命令**。当预设事件触发时，Claude 会将当前上下文状态打包成 JSON 格式，通过标准输入流（stdin）传递给 Hook 脚本；脚本执行完成后，通过退出码（exit code）或标准输出流（stdout）返回决策结果，Claude 会根据这一结果决定是否继续后续流程[(90)](https://juejin.cn/post/7634480263964819483)。

这一设计的核心区别于传统的 "技能注入" 类扩展方案：它是**确定性执行**的 —— 只要事件触发且匹配条件满足，Hook 脚本就必定会运行，不会因模型上下文稀释、长时间会话偏移或提示词注入攻击失效；而类似在 `CLAUDE.md` 中写入 "建议性规则" 的方式，本质是依赖模型的自主记忆与约束，在复杂场景下存在被忽略、被覆盖的风险[(44)](http://m.toutiao.com/group/7653321298067718671/)。

> 直观类比：Hooks 之于 Claude CLI，就如同 Git Hooks 之于 Git 版本控制。
>
> `pre-commit`
>
>  钩子会在提交代码前强制执行 lint 检查，不通过则无法提交；而 Claude 的 
>
> `PreToolUse`
>
>  钩子会在调用任何工具前强制进行安全检查，不通过则拦截后续操作 —— 两者的核心都是在关键生命周期节点注入确定性的自定义逻辑
>
> [(75)](https://aicoding.juejin.cn/post/7648862178301542435)
>
> 。

### 1.2 Hooks 的核心应用场景

基于事件驱动的特性，Hooks 能覆盖大量对**可控性**、**一致性**有硬性要求的工程化场景。根据官方最佳实践与社区落地案例，其典型用途可归纳为四大类：



| 场景类别      | 适用场景                              | 典型案例                                                |
| --------- | --------------------------------- | --------------------------------------------------- |
| **安全防护**  | 拦截危险操作、防范类漏洞执行、保护项目敏感资源           | 阻止 `rm -rf` 类破坏性命令、拦截强制推送 Git 主干分支、限制篡改 `.env` 配置文件 |
| **流程管控**  | 强制团队工作流规范、质量门禁校验、合规性检查            | 未通过单元测试不允许提交代码、代码格式化不通过拦截构建、提交前检查加密密钥               |
| **自动化扩展** | 减少手动重复操作、将多步人工流程串联为自动化流程          | 工具执行后自动格式化代码、会话启动时自动安装依赖、文件更新后自动重启应用                |
| **审计与通知** | 记录所有操作行为、将 Claude 状态同步给外部系统、日志持久化 | 记录每一条执行的 Shell 命令、会话结束时发送 Slack 通知、捕获错误时触发告警流程      |

需要明确的是，Hooks 并非 Claude CLI 唯一的扩展能力，而是与 Skills、MCP 协议形成了互补的扩展矩阵，各自承担不同的定制化场景。根据官方定义，三者的核心差异如下：



* **Hooks**：事件驱动的自动化脚本，核心价值是对 Claude 行为的确定性管控，可以拦截或修改工具的执行逻辑[(90)](https://juejin.cn/post/7634480263964819483)；

* **Skills**：是一组以 Markdown 格式编写的、Claude 可以自动调用的知识包，本质是注入上下文或开发规范，无法拦截操作，只能提供参考性指引[(90)](https://juejin.cn/post/7634480263964819483)；

* **MCP 协议**：是连接外部工具的标准协议，用于让 Claude 调用外部系统（如查询数据库、操作 GitHub、抓取网页），但无法干预 Claude 内部的执行流程[(90)](https://juejin.cn/post/7634480263964819483)。

### 1.3 Hooks 系统的核心组件

要完成从创建到实际触发运行的完整闭环，Claude CLI Hooks 系统需要三个核心组件协同工作。这一链路是理解 Hooks 工作原理的关键基础，其执行顺序是固定的，任何一个环节缺失都会导致 Hook 无法生效：



1. **事件（Event）** ：触发 Hook 执行的唯一触发点。Claude CLI 定义了覆盖完整生命周期的核心事件，从会话启动、用户提交输入、工具执行前后，到上下文压缩、会话结束，再到文件变更、配置修改甚至 Git 工作流操作，每个事件都代表 Claude 运行过程中的一个精准时间节点[(90)](https://juejin.cn/post/7634480263964819483)；

2. **配置（Configuration）** ：Claude 路由事件到对应脚本的精准规则，定义了 "在什么事件下、满足什么条件时、执行哪个脚本" 的映射关系。配置文件中需要指定事件类型、匹配规则、脚本路径或命令、超时时间、异步执行开关等关键参数[(90)](https://juejin.cn/post/7634480263964819483)；

3. **处理器（Handler）** ：包含用户自定义逻辑的可执行脚本或 API 端点，是 Hook 实际执行的核心载体，接收来自 Claude 的上下文输入，执行自定义的校验、修改或扩展逻辑，并返回明确的决策结果[(90)](https://juejin.cn/post/7634480263964819483)。

## 2. 理解 Hooks 事件模型

事件是 Hooks 机制的基础触发单位。Claude CLI 提供了覆盖完整生命周期的大量事件，允许用户在几乎所有关键节点注入自定义逻辑。选择合适的事件，是配置 Hook 的第一步 —— 在错误的事件节点挂载脚本，会导致 Hook 无法按预期触发。

### 2.1 核心生命周期事件

Claude CLI 的事件体系覆盖了从会话启动到结束的全链路流程，分为六大核心阶段，每个阶段包含多个精准事件。根据官方文档与社区使用频率，最常用的核心事件及触发时机如下表所示：



| 阶段            | 事件名称                 | 触发时机                                      | 关键能力                              |
| ------------- | -------------------- | ----------------------------------------- | --------------------------------- |
| **会话生命周期**    | `SessionStart`       | 新会话启动时触发                                  | 加载项目级环境变量、初始化审计日志目录               |
| **会话生命周期**    | `Setup`              | 项目初始化阶段触发（会话启动后仅触发一次）                     | 自动安装项目依赖、校验项目本地开发环境               |
| **会话生命周期**    | `SessionEnd`         | 会话终止或用户主动退出时触发                            | 归档会话审计日志、备份项目临时运行状态               |
| **用户输入处理**    | `UserPromptSubmit`   | 用户按下回车提交输入后、Claude 开始处理前触发                | 拦截或修改用户输入、过滤敏感提示词、补充上下文规则         |
| **工具执行前**     | `PreToolUse`         | Claude 调用任何工具（如 Bash、文件操作、Git 操作）**之前**触发 | 拦截危险操作、修改工具执行参数、增加审批逻辑、注入安全校验规则   |
| **工具执行前**     | `PermissionRequest`  | Claude 弹出权限确认窗口时触发                        | 自定义审批流程、自动批准特定合规操作、记录所有权限申请       |
| **工具执行后**     | `PostToolUse`        | 工具**成功**执行完成后触发                           | 自动格式化文件、代码质量扫描、记录审计日志、同步操作结果到外部系统 |
| **工具执行后**     | `PostToolUseFailure` | 工具执行**失败**后触发                             | 清理现场、记录错误日志、尝试自动恢复操作              |
| **上下文压缩**     | `PreCompact`         | Claude 压缩上下文（缩短历史记录）**之前**触发              | 提取关键操作日志、保存重要上下文状态、补充压缩提示词        |
| **上下文压缩**     | `PostCompact`        | 上下文压缩完成后触发                                | 备份压缩后的历史记录、统计上下文压缩效率              |
| **文件系统变更**    | `FileChanged`        | Claude 对项目文件进行写入、修改、删除操作后触发               | 自动重新加载配置文件、触发项目热更新、检查文件权限         |
| **Git 工作流操作** | `WorktreeCreate`     | 创建 Git 工作区后触发                             | 初始化新工作区的依赖安装、配置本地环境变量             |
| **Git 工作流操作** | `WorktreeRemove`     | 删除 Git 工作区后触发                             | 清理对应工作区的临时日志文件、归档工作区操作记录          |

每个事件都会向 Hook 脚本传递包含完整上下文信息的 JSON 输入，例如当前工作目录、用户 ID、工具执行参数、Claude 配置信息、会话 ID 等，为脚本的决策逻辑提供足够的运行时信息[(90)](https://juejin.cn/post/7634480263964819483)。

其中，`PreToolUse` 是整个 Hooks 体系中**最关键、使用频率最高**的事件 —— 它在工具执行前的拦截特性，是实现安全防护和流程管控的核心基础。与其他事件不同，`PreToolUse` 的脚本退出码可以直接终止后续流程：返回 `0` 表示 "放行"，Claude 会继续执行工具；返回 `2` 表示 "阻断"，Claude 会终止工具调用；返回其他非 `0` 码会记录错误信息但不强制阻断。这一决策机制是实现拦截类 Hook 的核心基础[(90)](https://juejin.cn/post/7634480263964819483)。

### 2.2 事件匹配与条件过滤

Claude CLI 提供了两层精准过滤机制，避免无意义的 Hook 触发，保证只有当工具名、参数同时匹配特定规则时，Hook 才会执行。这一设计可以大幅减少 Hook 脚本的执行次数，提升整体性能，同时避免在脚本内部实现复杂的过滤逻辑。

#### 2.2.1  matcher 工具名正则匹配

`matcher` 是事件级的过滤规则，它会对 Claude 将要调用的**工具名称**做正则表达式匹配。只有匹配成功的事件，才会进入后续的处理器级过滤逻辑。`matcher` 的正则语法遵循 JavaScript 正则表达式标准，在配置文件中直接写正则的匹配内容即可，无需额外添加正则分隔符。

例如，在 `PreToolUse` 事件的配置中，设置 `"matcher": "Bash"` 表示仅匹配 Bash 类的工具调用；设置 `"matcher": "Edit|Write"` 表示匹配文件编辑或写入类的工具调用；如果设置为 `"matcher": "*"` 或省略该字段，则表示匹配所有工具的调用。

#### 2.2.2  if 条件参数匹配

`if` 是处理器级的额外过滤规则，它在 `matcher` 匹配成功后执行，可以同时对**工具名**和**调用参数**进行更精细的语义级过滤，完全基于权限规则语法进行配置。

这意味着，你可以在 `if` 条件中定义更具体的参数校验逻辑，例如：



* 仅匹配 " 以 `rm` 开头的 Bash 命令 "，而不是所有 Bash 工具调用；

* 仅匹配 " 对项目中 `.env` 后缀文件的编辑或写入操作 "，而不是所有文件操作；

* 仅匹配 " 目标为 `main` 分支的 Git 强制推送命令 "，而不是所有 Git 操作。

`if` 条件的配置格式为 `工具名(参数匹配规则)`，支持使用 `*` 作为通配符，例如 `Bash(rm *)`、`Edit(*.env)`、`Bash(git push --force main)`。

#### 2.2.3 两层过滤的组合逻辑

`matcher` 和 `if` 条件是**与的关系**：只有当事件的工具名匹配 `matcher` 正则表达式，且工具的调用参数匹配 `if` 条件规则时，对应的 Hook 脚本才会被执行。

两者的分工有明确区别，在配置 Hook 时需要根据实际需求选择合适的过滤层级：



* `matcher` 负责粗粒度的工具名级过滤，性能开销更小；

* `if` 条件负责细粒度的参数级过滤，匹配精度更高。

> 工程化最佳实践：应该优先使用 
>
> `matcher`
>
>  过滤掉不需要的工具类型，再通过 
>
> `if`
>
>  条件过滤出需要拦截的具体参数组合 —— 将匹配工作放在配置层而非脚本层，能有效避免不必要的脚本执行开销，也让配置逻辑更清晰易读
>
> [(90)](https://juejin.cn/post/7634480263964819483)
>
> 。

### 2.3 事件执行顺序

Claude CLI 触发事件的顺序是完全确定的，与用户的操作流程一一对应。以一个典型的 "用户提交输入→Claude 调用工具→处理结果返回" 流程为例，事件的触发顺序如下：



```
SessionStart → Setup → UserPromptSubmit → PreToolUse → PermissionRequest → \[Tool Execution] → PostToolUse → PostToolUseFailure/PostToolBatch → PreCompact → PostCompact → Stop → SessionEnd
```

如果配置了多个 Hook 监听同一个事件（例如两个 Hook 都监听 `PreToolUse` 事件），Claude 会按照配置文件中的**先后顺序**依次执行这些 Hook 脚本。需要特别注意的是，**同步 Hook 会阻塞主流程执行**—— 必须等到当前 Hook 执行完成后，才会触发下一个 Hook 或后续流程。如果前一个 Hook 脚本执行时间过长，会阻塞整个 Claude 的执行流程。

## 3. 创建 Hooks：语法、结构与脚本编写

要创建一个可用的 Hook，一般需要遵循 "创建目录结构→编写自定义逻辑脚本→在配置文件中注册规则→验证配置有效性" 的标准流程。这一流程对所有类型的 Hook 是统一的，区别仅在于脚本的逻辑和配置的参数。

### 3.1  Hooks 目录结构规划

在编写脚本和配置文件之前，建议先规划好项目的 Hooks 相关目录结构，保证配置的统一性、可维护性，同时避免后续配置文件中的路径引用错误。Claude CLI 对 Hooks 的目录结构没有强制约束，但官方和社区都推荐采用以下标准结构，来管理不同作用域的配置和脚本文件：



```
你的项目根目录/

├── .claude/                # Claude CLI 所有配置文件的根目录（必须在项目根目录下）

│   ├── settings.json      # 项目级配置文件，可提交到代码仓库，团队成员共享

│   ├── settings.local.json# 项目本地专属配置文件，需配置 .gitignore 忽略，用于个人覆盖项目级配置

│   └── hooks/              # 所有自定义 Hook 脚本的统一存放目录

│       ├── block-rm-rf.sh # 自定义 Hook 脚本示例

│       ├── protect-files.py

│       └── utils/          # 可选：存放 Hook 脚本引用的公共依赖、工具或库

└── ...
```

在这个标准目录结构中，有两个关键要求必须严格遵循：



* 配置文件的目录名必须是 `.claude`，且必须放在项目的根目录下 ——Claude 启动时会从当前工作目录向上查找这一目录，若路径不正确，配置将无法被加载；

* 所有可执行的 Hook 脚本必须放在 `.claude/hooks/` 目录下 —— 这是为了保证项目的可移植性，也便于在 Git 中统一忽略或追踪相关文件。

你可以根据项目的实际技术栈需求，在 `hooks/` 目录下进一步组织子目录，例如将 Shell 脚本、Python 脚本、Node.js 脚本分开放置，或按业务场景将同一类型的 Hook 脚本放在同一个子目录下。

### 3.2 编写 Hook 处理器脚本

Hook 脚本是 Claude 扩展能力的核心载体 —— 理论上，任何可以在终端内独立运行的语言（如 Bash、Python、Node.js、Ruby 等），都可以用来编写 Hook 的自定义逻辑。Claude 与 Hook 脚本之间，通过标准输入流（stdin）、标准输出流（stdout）和退出码（exit code）这三组标准流进行数据交互。

#### 3.2.1 脚本输入规范

Claude 会在事件触发时，将完整的运行时上下文信息打包为标准 JSON 格式，通过标准输入流（stdin）发送给 Hook 脚本。脚本可以从 stdin 中读取这一 JSON 字符串，提取所需的工具名称、执行参数、用户 ID、会话 ID、工作目录等关键上下文信息，作为后续自定义逻辑的判断依据[(90)](https://juejin.cn/post/7634480263964819483)。

根据事件类型的不同，这一 JSON 结构体的具体字段会有差异，但所有事件的输入 JSON 都会包含以下 4 个基础字段：



* `tool_name`：触发当前 Hook 事件的工具名称，与 `matcher` 匹配的内容完全一致；

* `tool_input`：工具的实际执行参数，是一个嵌套的 JSON 对象，具体结构由工具类型决定 —— 例如 Bash 工具会包含 `command` 字段，文件编辑工具会包含 `file_path` 和 `content` 字段；

* `cwd`：Claude CLI 当前的工作目录，即启动 Claude 时所在的目录；

* `event_id`：当前事件的唯一标识符，可用于日志追踪或关联同一批执行的事件。

例如，当用户尝试执行 `rm -rf /tmp/build` 命令时，`PreToolUse` 事件发送给 Hook 脚本的输入 JSON 结构如下：



```
{

&#x20; "tool\_name": "Bash",

&#x20; "tool\_input": {

&#x20;   "command": "rm -rf /tmp/build"

&#x20; },

&#x20; "cwd": "/home/user/project",

&#x20; "event\_id": "a1b2c3d4-5678-90ef-ghij-klmnopqrstuv"

}
```

#### 3.2.2 脚本输出与退出码决策规范

Hook 脚本的标准输出流（stdout）和退出码（exit code），是 Claude 唯一能识别的决策依据，必须严格遵循规范返回结果。脚本需要根据自身逻辑的执行结果，返回符合特定规范的输出或退出码，Claude 会根据这些信息决定后续的执行流程。

不同事件类型的 Hook，对输出和退出码的处理逻辑存在差异，具体要求如下表所示：



| 事件类型                               | 退出码 / 输出               | 行为说明                              |
| ---------------------------------- | ---------------------- | --------------------------------- |
| `PreToolUse`、`PermissionRequest`   | **exit 0**             | 验证通过，Claude 会继续执行后续的工具调用或流程       |
| `PreToolUse`、`PermissionRequest`   | **exit 2**             | 验证失败，Claude 会立即阻断后续的工具调用流程        |
| `PreToolUse`、`PermissionRequest`   | **其他非 0 码**            | 表示脚本执行异常，Claude 会记录错误日志，但不会阻断后续流程 |
| `PostToolUse`、`SessionEnd` 等非阻断类事件 | **exit 0**             | 表示脚本执行成功，不影响 Claude 的后续流程         |
| 所有支持阻断的事件类型                        | **stdout 输出 JSON 字符串** | 可以返回更复杂的决策结果，如自定义提示信息、修改后的工具执行参数  |

需要特别注意的是，**如果 Hook 脚本需要返回阻断决策，必须通过标准错误流（stderr）输出详细的错误信息**——Claude 会将这部分信息捕获并展示给用户，或记录到审计日志中。如果直接将错误信息输出到 stdout，可能会被 Claude 识别为正常的决策结果，导致预期外的行为。

对于需要修改工具输入的 `PreToolUse` 类 Hook，脚本可以通过 stdout 输出 JSON 字符串，来覆盖原有的工具执行参数 —— 这一特性常被用于删除危险的参数、添加安全的默认参数，或统一修改命令的执行路径。例如：



```
{

&#x20; "tool\_input": {

&#x20;   "command": "rm -rf /tmp/build --preserve-root"

&#x20; }

}
```

#### 3.2.3 脚本编写的跨平台注意事项

在编写 Hook 脚本时，必须考虑跨平台兼容性 ——Claude CLI 支持 Windows、macOS、Linux 三大主流操作系统，而不同操作系统对脚本的执行环境、默认编码、行尾符的处理逻辑存在差异。如果脚本未做兼容处理，在不同平台上可能会出现执行失败、逻辑错误或编码异常等问题。

根据官方的兼容性指南，跨平台 Hook 脚本需要特别注意三个关键细节：



* **脚本解释器的可移植性**：Shell 脚本在 Windows 上需要通过 Git Bash、WSL 或 Cygwin 等兼容层执行，因此脚本的文件路径中不能包含空格或特殊字符；PowerShell 脚本在跨平台时，需要额外处理命令的参数转义；

* **UTF-8 编码强制要求**：Claude 与 Hook 脚本之间的所有数据交互，都必须使用 UTF-8 编码 —— 否则，在传递中文、日文等非 ASCII 字符时，可能会出现乱码，导致 JSON 解析失败。这一问题在 Windows 平台上尤其容易出现：cmd.exe 默认使用 GBK 编码，Python 的 `print` 函数默认编码也不是 UTF-8。解决方案是：在 Python 脚本头部添加 `# -*- coding: utf-8 -*-` 声明，输出 JSON 字符串时，使用 `sys.stdout.buffer.write(json.dumps(result).encode('utf-8'))` 方法；

* **行尾符的统一处理**：Shell 脚本必须使用 LF（`\n`）作为行尾符，不能使用 CRLF（`\r\n`）—— 否则，在 Linux/macOS 系统上执行脚本时，会出现 "未找到命令" 的错误。可以通过配置 Git 的 `core.autocrlf` 规则，或在编辑器中手动设置行尾符，来保证行尾符的一致性。

#### 3.2.4 脚本编写示例

下面以一个实际的安全拦截 Hook 为例，展示脚本的编写规范 —— 这是一个 `PreToolUse` 事件的 Hook，功能是拦截所有包含 `rm -rf` 或 `rm -r -f` 模式的危险 Bash 命令，避免用户误删系统级或项目级的关键目录或文件。

**示例脚本：**`.claude/hooks/block-rm-rf.sh`



```
\#!/bin/bash

\# 从标准输入（stdin）中读取 Claude 发送的完整上下文 JSON

INPUT\_JSON=\$(cat)

\# 使用 jq 工具从 JSON 中提取 Bash 命令的实际内容

\# jq 是一个命令行 JSON 解析器，需要额外安装（详见 4.2 环境依赖准备）

COMMAND=\$(echo "\$INPUT\_JSON" | jq -r '.tool\_input.command')

\# 检测命令中是否包含危险的删除模式：rm -rf 或 rm -r -f

if echo "\$COMMAND" | grep -qE 'rm\s+(-rf|-r\s+-f)'; then

&#x20; \# 如果匹配到危险命令，通过标准错误流（stderr）输出用户可理解的错误信息

&#x20; echo "错误：当前项目禁止使用 rm -rf 类破坏性删除命令" >&2

&#x20; echo "详情：检测到危险删除命令，Hook 已阻断其执行" >&2

&#x20; \# 退出码 2 通知 Claude 终止后续的工具调用流程

&#x20; exit 2

fi

\# 如果命令不匹配危险模式，退出码 0 通知 Claude 继续执行工具调用

exit 0
```

这个脚本是 Hook 拦截类场景的典型实现，包含了这类脚本的标准逻辑流程：从 stdin 读取输入 JSON、提取关键参数内容、通过自定义逻辑判断是否允许执行、最后通过退出码返回明确决策。

### 3.3 配置 Hooks：注册事件与脚本映射

编写完 Hook 脚本后，需要在 `settings.json` 配置文件中**注册**这个脚本，将其与特定的事件、匹配规则关联起来 —— 这是让 Claude 知道 "在什么场景下执行哪个脚本" 的唯一方式。如果不进行这一步配置，Claude 会完全忽略 Hook 脚本的存在，即使事件触发也不会执行。

#### 3.3.1 配置文件的层级结构

Claude CLI 的 Hook 配置采用三层层级结构，从高到低分别是事件、匹配器组、处理器列表，这一结构定义了完整的事件路由规则。配置的根节点必须是 `hooks` 字段，其下的第一层是事件名称，第二层是 `matcher` 匹配规则，第三层是挂载的 Hook 处理器脚本。配置的完整结构如下：



```
{

&#x20; "hooks": {

&#x20;   "事件名": \[

&#x20;     {

&#x20;       "matcher": "匹配器正则表达式",

&#x20;       "if": "处理器级额外条件",

&#x20;       "hooks": \[

&#x20;         {

&#x20;           "type": "处理器类型",

&#x20;           "command": "脚本路径或HTTP地址",

&#x20;           "timeout": 超时秒数,

&#x20;           "async": 是否异步执行,

&#x20;           "working\_dir": "脚本执行的工作目录"

&#x20;         }

&#x20;       ]

&#x20;     }

&#x20;   ]

&#x20; }

}
```

#### 3.3.2 配置字段详细说明

配置文件中有多个核心字段，需要根据实际场景配置正确的参数。这些字段的名称、取值范围、默认值都有严格规范，错误的字段配置会导致 Hook 无法正常加载或执行。



| 字段名           | 含义说明                       | 取值范围 / 示例                                            | 默认值                 |
| ------------- | -------------------------- | ---------------------------------------------------- | ------------------- |
| `hooks`       | 配置文件的根节点，包含所有事件类型的 Hook 配置 | 键为事件名称，值为该事件的匹配规则与处理器列表                              | 无（必填字段）             |
| **事件名**       | 要监听的 Claude 生命周期事件名称       | 所有支持的事件名，如 `PreToolUse`、`PostToolUse`、`SessionStart` | 无（必填字段）             |
| `matcher`     | 事件级的工具名正则匹配表达式             | 如 `Bash`、\`Edit                                      | Write`、`\*\`        |
| `if`          | 处理器级的额外过滤条件，使用权限规则语法       | 如 `Bash(rm *)`、`Edit(*.env)`                         | 无（不做额外过滤）           |
| `hooks`       | 匹配成功后需要执行的处理器列表            | 包含多个处理器配置的数组                                         | 无（必填字段）             |
| `type`        | 处理器的类型，决定 Hook 的执行方式       | 可选值：`command`、`http`、`mcp_tool`、`prompt`、`agent`     | `command`           |
| `command`     | 处理器的实际执行内容，根据类型不同含义不同      | 类型为 `command` 时是脚本的相对路径或完整命令；类型为 `http` 时是完整的 API 地址 | 无（必填字段）             |
| `timeout`     | Hook 脚本的执行超时时间，单位为秒        | 如 `30`、`600`（10 分钟）                                  | `60`                |
| `async`       | 是否以异步模式执行 Hook 脚本          | `true` 表示异步执行，`false` 表示同步执行                         | `false`             |
| `working_dir` | 脚本的执行工作目录，支持 Claude 内置变量   | 如 `$CLAUDE_PROJECT_DIR`、`~/.claude/hooks`            | 无（使用 Claude 当前工作目录） |

#### 3.3.3 处理器类型说明

Claude CLI 的 Hook 处理器有 5 种类型，分别对应不同的扩展场景。这一设计的核心是为了满足不同复杂度的需求：简单的逻辑可以直接用 Shell 脚本实现，复杂的逻辑可以调用外部服务或编程语言 SDK 实现。

其中，`command` 类型是最常用、兼容性最好的处理器类型 —— 社区 90% 以上的 Hook 都采用该类型。这是因为它直接复用系统终端的脚本执行能力，不需要额外的 Web 服务或 MCP 工具配置，在本地开发和 CI/CD 场景中都能直接使用。



| 处理器类型      | 描述                         | 典型场景                              |
| ---------- | -------------------------- | --------------------------------- |
| `command`  | 执行一个本地终端命令或脚本              | 运行 Shell/Python 脚本、调用本地命令行工具      |
| `http`     | 发送 HTTP/HTTPS 请求到外部 Web 服务 | 调用第三方安全扫描 API、将审计日志发送到外部系统        |
| `mcp_tool` | 调用一个配置好的 MCP 协议工具          | 对 Hook 逻辑进行复杂编程级封装、调用外部业务系统接口     |
| `prompt`   | 使用 Claude 自身的模型判断力进行验证     | 当脚本中需要使用 Claude 模型的理解能力时，自动生成审查意见 |
| `agent`    | 启动一个子 Agent 来处理更复杂的判断逻辑    | 多步骤复杂工作流、需要模型多次交互的决策或代码级验证        |

#### 3.3.4 配置示例

下面是一个与前文脚本示例对应的完整配置示例，它将 `block-rm-rf.sh` 脚本与 `PreToolUse` 事件关联起来，实现了拦截危险删除命令的核心逻辑。



```
{

&#x20; "hooks": {

&#x20;   "PreToolUse": \[

&#x20;     {

&#x20;       "matcher": "Bash",

&#x20;       "if": "Bash(rm \*)",

&#x20;       "hooks": \[

&#x20;         {

&#x20;           "type": "command",

&#x20;           "command": "bash \\"\$CLAUDE\_PROJECT\_DIR/.claude/hooks/block-rm-rf.sh\\"",

&#x20;           "timeout": 10,

&#x20;           "async": false

&#x20;         }

&#x20;       ]

&#x20;     }

&#x20;   ]

&#x20; }

}
```

在这个配置中，`command` 字段使用了 `$CLAUDE_PROJECT_DIR` 变量 —— 这是 Claude 提供的内置环境变量，自动解析为当前项目根目录的绝对路径（即 `.claude` 目录的上级目录）。推荐在配置文件中优先使用这一变量来引用 Hook 脚本，这能保证配置在不同开发环境、不同操作系统上的一致性，避免因项目路径不同导致的脚本找不到错误。

### 3.4 使用 Hook 管理命令自动创建

除了手动编写配置文件外，Claude CLI 还提供了 `hookify` 官方插件，支持用**自然语言描述** Hook 规则 —— 插件会自动生成对应的脚本和配置文件，无需手动编辑 JSON 配置或编写脚本代码。

这一工具的核心是为了降低 Hook 的使用门槛，让不熟悉 JSON 配置或脚本编写的用户，也能通过简单的自然语言描述，快速实现自己的 Hook 规则。例如，你可以在 Claude 的交互式会话中，直接用自然语言描述 Hook 规则：



```
/hookify 当执行 rm -rf 类命令时进行拦截

/hookify 当执行的Git命令包含git push --force时进行拦截

/hookify 提交代码时自动检查遗留的console.log语句
```

`hookify` 插件会自动分析这些自然语言规则，生成对应的匹配条件、脚本代码和完整的 `settings.json` 配置项，完全不需要手动编辑配置文件或脚本。此外，你还可以通过 `/hookify:list` 命令列出当前项目中所有已配置的 Hook 规则，通过 `/hookify:setup` 命令交互式选择需要启用的 Hook 规则，或通过 `/hookify:disable` 命令禁用指定的 Hook 规则。

## 4. 安装与配置 Hooks

Hooks 的安装本质是将编写好的脚本和配置文件，放置到 Claude 可以识别的正确路径下，或通过 CLI 命令启用对应的配置。Claude CLI 提供了多种安装方式，覆盖从手动配置到社区插件安装的不同场景，用户可以根据自己的需求选择合适的方式。

### 4.1 安装方式选择

Claude CLI 支持三类 Hook 安装方式，覆盖从个人本地临时配置到团队共享生产配置的场景级需求。不同方式的安装流程、适用场景和共享能力不同，有明确的优先级划分。

#### 4.1.1 安装方式分类



| 方式              | 适用场景                             | 共享能力                      | 配置优先级 |
| --------------- | -------------------------------- | ------------------------- | ----- |
| **手动安装**        | 从头开始编写自定义逻辑，完全控制 Hook 脚本的内容      | 需手动分发脚本和配置文件              | 低     |
| **Git 克隆安装**    | 安装社区或团队共享的 Hook 脚本集合             | 可通过 Git 仓库进行版本化团队共享       | 中     |
| **Plugin 市场安装** | 安装第三方或官方的完整 Hook 插件，包含完整的自动化配置逻辑 | 可通过 Plugin 市场进行版本化管理与团队共享 | 高     |

#### 4.1.2 安装优先级

Claude CLI 会按照**从低到高**的优先级顺序，加载所有配置文件中的 Hook 规则。如果多个配置文件中存在事件、匹配条件完全相同的 Hook 规则，高优先级的配置会**覆盖**低优先级的配置，执行高优先级的 Hook 脚本。

具体优先级规则如下：



1. 插件级的 `hooks/hooks.json` 配置文件（随插件安装）优先级最低；

2. 项目级的 `.claude/settings.json` 配置文件（团队共享）优先级次之；

3. 项目本地的 `.claude/settings.local.json` 配置文件（个人本地覆盖）优先级更高；

4. 用户全局的 `~/.claude/settings.json` 配置文件（所有项目生效）优先级最高。

因此，在实际使用中：



* 团队共享的规则，应该放在项目级的 `.claude/settings.json` 文件中，并提交到 Git 仓库；

* 个人本地的临时覆盖规则，应该放在项目本地的 `.claude/settings.local.json` 文件中，并在 Git 仓库中配置忽略；

* 跨项目的全局规则，应该放在用户全局的 `~/.claude/settings.json` 文件中。

### 4.2 安装前的环境依赖准备

在安装 Hook 之前，需要先确保本地 Claude 环境的基础依赖已经安装完成。如果依赖未安装或版本不兼容，Hook 脚本可能会出现执行失败、逻辑错误、编码乱码或超时等问题。

根据官方的环境要求清单，运行 Hooks 前需要确保本地环境满足以下条件：



* **Claude CLI 版本兼容**：需要确保 Claude CLI 的版本不低于 `0.1.0`—— 这是第一个稳定支持 Hooks 机制的正式版本。如果是旧版本，需要先通过 `claude upgrade` 命令升级到最新版本，避免出现配置不兼容的问题；

* **脚本解释器安装**：Claude CLI 本身不自带脚本解释器，需要确保本地环境安装了 Hook 脚本对应的语言解释器 —— 例如执行 Shell 脚本需要安装 Bash 或 Sh 解释器，执行 Python 脚本需要安装 Python 3.6 或更高版本，执行 Node.js 脚本需要安装 Node.js 12 或更高版本；

* **jq 工具安装**：`jq` 是一个轻量级的命令行 JSON 解析器，用于处理 Claude 与 Hook 脚本之间传递的 JSON 数据。大部分 Hook 脚本都依赖这个工具来解析输入的 JSON 内容，因此需要预先安装。安装方法根据操作系统的不同而不同：


  * 对于 Ubuntu/Debian 系统，可以通过 `sudo apt-get install jq` 命令安装；

  * 对于 CentOS/RHEL 系统，可以通过 `sudo yum install jq` 命令安装；

  * 对于 macOS 系统，可以通过 Homebrew 包管理器，执行 `brew install jq` 命令安装；

  * 对于 Windows 系统，可以通过 Winget 包管理器，执行 `winget install jqlang.jq` 命令安装，或通过 Scoop 包管理器，执行 `scoop install jq` 命令安装；

* **脚本执行权限授予**：Hook 脚本需要有可执行权限才能运行 —— 在 macOS 或 Linux 系统上，需要先在终端切换到项目根目录，然后执行 `chmod +x .claude/hooks/*.sh` 和 `chmod +x .claude/hooks/*.py` 命令，给所有 Hook 脚本添加可执行权限。Windows 系统不需要额外修改权限，但需要确保脚本的解释器在系统的 `PATH` 环境变量中。

### 4.3 手动安装流程

手动安装是最基础的 Hook 安装方式，适用于从头开发自定义 Hook 逻辑的场景。在这种方式下，需要手动创建所有目录结构、编写脚本代码、编辑配置文件，整个过程完全可控，可以自定义所有细节。

安装步骤如下：



1. **创建配置目录**：在项目的根目录下，创建 `.claude` 配置目录和 `hooks` 脚本存放目录。如果是在 macOS 或 Linux 系统上，可以直接在终端中执行 `mkdir -p .claude/hooks` 命令来创建这两个目录；如果是在 Windows 系统上，可以通过文件资源管理器或 `mkdir .claude\hooks` 命令创建。

2. **放置脚本文件**：将编写好的 Hook 脚本文件，统一放到 `.claude/hooks/` 目录下。

3. **授予脚本执行权限**：在 macOS 或 Linux 系统上，需要执行 `chmod +x .claude/hooks/*.sh` 和 `chmod +x .claude/hooks/*.py` 命令，给所有脚本添加可执行权限。

4. **注册 Hook 配置**：在 `.claude` 目录下创建 `settings.json` 配置文件，并添加完整的 `hooks` 配置项 —— 可以参考前文提供的配置示例，将其中的脚本路径、匹配规则、事件类型等参数替换为实际的内容。

5. **验证配置文件的有效性**：在终端中执行 `jq . .claude/settings.json` 命令，验证配置文件的 JSON 格式是否正确 —— 如果格式有误，命令会输出明确的错误提示，需要修复后再继续；如果格式正确，命令会将配置文件的内容格式化输出到终端中。

### 4.4 安装社区或第三方 Hooks

社区或第三方 Hooks 是指由其他用户或团队开发的、可直接复用的 Hook 逻辑，覆盖了安全防护、代码质量、工作流优化等常见场景。这类 Hook 一般已经发布到 Claude 的 Plugin 市场，或托管在 GitHub 之类的代码仓库中，可以通过 CLI 命令直接安装，无需手动编写脚本或配置。

#### 4.4.1 通过 Plugin 市场安装

Plugin 市场是官方推荐的安装方式，它会自动处理 Hook 的所有依赖、配置和更新逻辑，全程不需要手动修改任何文件。以社区流行的 `tdd-guard` 插件（强制 TDD 工作流的 Hook 集合）为例，安装步骤如下：



1. 启动 Claude CLI 的交互式会话 —— 可以在终端中执行 `claude` 命令启动；

2. 执行插件市场的添加命令，将插件的远程仓库地址添加到本地市场列表中：



```
/plugin marketplace add nizos/tdd-guard
```



1. 执行插件安装命令，安装对应版本的插件包：



```
/plugin install tdd-guard@tdd-guard
```



1. 部分插件需要额外的初始化配置才能正常使用 —— 可以执行插件的初始化命令，启用所有相关 Hook 规则：



```
/tdd-guard:setup
```

安装完成后，Claude 会自动加载插件中的所有 Hook 规则 —— 无需手动修改 `settings.json` 配置文件，也无需额外设置脚本执行权限。

#### 4.4.2 通过 Git 克隆安装

部分社区或团队的 Hook 集合，可能没有发布到 Plugin 市场，而是直接托管在 Git 仓库中。这类 Hook 可以通过 Git 克隆的方式安装，将仓库中的所有脚本和配置文件，直接复制到项目的 `.claude/hooks/` 目录下。

以社区的 `claude-hook-cookbook` 仓库（包含 9 个生产级可用的 Hook 脚本）为例，安装步骤如下：



1. 打开终端，切换到项目的根目录下；

2. 执行 `git clone` 命令，将远程仓库克隆到项目的 `.claude/hooks/` 目录下：



```
git clone https://github.com/echo-lumen/claude-hook-cookbook.git .claude/hooks/cookbook
```



1. 克隆完成后，将仓库中的配置内容，合并到项目级的 `.claude/settings.json` 配置文件中 —— 需要将仓库中 `settings.json` 里的 `hooks` 配置项，复制到项目的配置文件中；

2. 给脚本添加执行权限：



```
chmod +x .claude/hooks/cookbook/\*.sh
```

### 4.5 验证安装与配置

安装完成后，需要验证 Hook 是否正确安装并被 Claude 加载。如果不进行验证，可能会出现配置正确但 Hook 未生效的情况，影响后续使用。验证方式分为配置文件校验、列出已加载 Hook 规则、触发测试场景三步操作。

#### 4.5.1 校验配置文件的有效性

在终端中执行 `jq . .claude/settings.json` 命令，检查配置文件的 JSON 格式是否正确 —— 如果配置文件的格式有误，命令会输出明确的错误行号和原因，需要先修复该问题。

#### 4.5.2 查看已加载的 Hook 规则

在 Claude 交互式会话中，执行 `/plugin list` 命令，查看所有已安装的插件及关联的 Hook 规则 —— 如果配置正确，你安装的 Hook 规则和关联的插件会出现在返回列表中；如果没有出现，说明插件安装或配置文件加载存在问题。

#### 4.5.3 触发实际事件验证

最后，需要实际触发一个 Hook 监听的事件，验证脚本是否按预期执行。例如，对于前文的 `block-rm-rf.sh` 脚本，可以让 Claude 尝试执行一个包含 `rm -rf` 的命令：



```
帮我删除/tmp/build目录：rm -rf /tmp/build
```

如果 Hook 配置正确，Claude 会在执行命令前触发 `PreToolUse` 事件，执行对应的拦截脚本，在终端中输出你在脚本中定义的错误信息，并且不会真正执行 `rm -rf` 命令；如果没有按预期拦截，说明 Hook 的配置或脚本逻辑存在问题，需要根据日志信息进行排查。

## 5. 调用与使用 Hooks

Hooks 不需要手动调用或激活 —— 这是其作为 "确定性自动化脚本" 的核心特性之一。只要配置正确，Claude 会在其生命周期的特定事件节点上，**自动触发**所有满足条件的 Hook 规则，完全不需要人工干预。

### 5.1 触发 Hooks 的条件

在实际运行中，一个 Hook 能否被触发执行，取决于三个必要条件 —— 这三个条件是**逻辑与**的关系，必须同时满足，Hook 才会被执行。



1. **事件匹配**：Claude 实际触发的生命周期事件名称，必须与 Hook 配置中监听的事件名称完全匹配。例如，配置中监听的是 `PreToolUse` 事件，那么只有在工具执行前，Hook 才会被触发；如果是 `PostToolUse` 事件触发的流程，这个 Hook 就不会被执行。

2. **过滤器匹配**：事件的实际工具名称和参数，必须与 Hook 配置中的 `matcher` 正则表达式和 `if` 条件同时匹配。Claude 会先检查工具名是否匹配 `matcher` 正则表达式，再检查调用参数是否满足 `if` 条件 —— 只有两个条件都匹配时，才会执行后续的 Hook 脚本。

3. **脚本存在且有执行权限**：配置文件中指定的 Hook 脚本路径必须正确，脚本文件必须存在，且有足够的执行权限（在 macOS/Linux 系统上需要有 `+x` 权限，在 Windows 系统上需要脚本解释器在 `PATH` 环境变量中）。如果脚本不存在或没有执行权限，Claude 会在日志中记录明确的错误信息，但不会影响主流程的执行。

### 5.2 Hooks 的执行流程

当事件被触发时，Claude 会按照固定的内部流程处理所有匹配的 Hook 规则。这一流程是串行执行的，同一个事件的多个 Hook 会按照配置中的顺序依次执行。

以 `PreToolUse` 事件为例，完整的 Hook 执行链路如下：



1. Claude 即将执行一个工具调用，触发 `PreToolUse` 事件；

2. Claude 检查所有配置文件中，监听 `PreToolUse` 事件的 Hook 规则，过滤出 `matcher` 和 `if` 条件都匹配的所有 Hook；

3. 对筛选出的每一个 Hook，Claude 会根据配置文件中的 `command` 或 `http` 等字段，启动对应的脚本或 HTTP 请求；

4. Claude 将运行时上下文数据，打包成 JSON 格式，通过标准输入流（stdin）或 HTTP 请求体，发送给 Hook 脚本或外部服务；

5. Hook 脚本或服务执行自定义的校验、修改或扩展逻辑，通过退出码或标准输出流返回决策结果；

6. Claude 读取并解析 Hook 脚本或服务的返回结果，根据决策结果执行后续操作：

* 如果任意一个 Hook 脚本返回了**阻断**决策（exit code 2），Claude 会立即终止后续的工具执行流程，不再触发后续的 Hook 规则；

* 如果所有 Hook 脚本都返回**放行**决策（exit code 0），Claude 会继续执行后续的工具调用流程；

* 如果 Hook 脚本修改了工具的输入参数，Claude 会使用修改后的参数来执行工具；

1. 所有 Hook 执行完成后，Claude 会将本次 Hook 的所有执行结果，记录到会话日志中 —— 包括脚本的退出码、stdout 输出、执行耗时、错误信息等，便于后续排查问题。

> 工程化最佳实践：在实际项目中，建议将 
>
> `PreToolUse`
>
>  类的拦截性 Hook 规则，放在项目级的 
>
> `.claude/settings.json`
>
>  文件中，强制所有团队成员共享；而将 
>
> `PostToolUse`
>
>  类的辅助性 Hook 规则，放在个人级的 
>
> `settings.local.json`
>
>  文件中，避免不同开发环境下的逻辑冲突。

### 5.3 处理 Hook 的执行结果

根据事件类型的不同，Hook 脚本的返回结果会对 Claude 的后续流程产生不同程度的影响。Claude 设计了一套灵活的决策系统，允许 Hook 脚本以不同的方式影响主流程，或返回需要记录的额外信息。

#### 5.3.1 决策结果

对于支持拦截操作的事件类型（如 `PreToolUse`、`PermissionRequest`），Hook 脚本的返回结果，会直接决定 Claude 是否继续执行后续的流程。这类 Hook 脚本的决策结果，有且仅有三种标准类型：



| 决策类型          | 含义说明                          | 实现方式                                                      |
| ------------- | ----------------------------- | --------------------------------------------------------- |
| **允许（allow）** | 验证通过，Claude 会继续执行后续的工具调用或流程   | 脚本返回 exit code 0，或输出 `{"is_approved": true}` 格式的 JSON 内容  |
| **拒绝（deny）**  | 验证失败，Claude 会立即阻断后续的工具调用流程    | 脚本返回 exit code 2，或输出 `{"is_approved": false}` 格式的 JSON 内容 |
| **询问（ask）**   | 脚本没有做出明确决策，让 Claude 询问用户的审批意见 | 脚本输出 `{"decision": "ask"}` 格式的 JSON 内容                    |

如果同一个事件触发了多个 Hook 规则，且它们返回了不同的决策结果，Claude 会按照**拒绝 > 询问 > 允许**的优先级顺序，执行优先级最高的决策结果。例如，即使大部分 Hook 脚本返回 "允许"，只要有一个 Hook 脚本返回 "拒绝"，Claude 就会终止后续的工具执行流程。

#### 5.3.2 额外的上下文处理

除了直接的决策结果外，部分类型的 Hook 脚本，还可以通过 stdout 输出特定格式的 JSON 字符串，返回额外的元数据，对 Claude 的主流程产生更精细的影响。

这类额外的返回信息中，最常用的有两类：



* **修改后的工具输入参数**：`PreToolUse` 类 Hook 脚本可以返回修改后的 `tool_input` 参数，覆盖 Claude 原来的执行参数。例如，给危险的命令添加 `--preserve-root` 之类的安全参数；

* **附加的上下文信息**：Hook 脚本可以返回 `additionalContext` 字段，其中的文本信息会被追加到 Claude 本次工具调用的上下文提示中。例如，在拦截脚本中返回 `"additionalContext": "已通过安全校验，该操作符合项目安全规范"`，Claude 会将这段信息展示在本次执行的日志中。

### 5.4 实战场景示例

下面通过两个真实的生产级示例，展示 Hooks 在实际场景中的使用方法。这两个示例分别覆盖了安全防护和自动化扩展两类最常用的场景，都是社区中已经经过大量项目验证的生产级实现。

#### 5.4.1 实战场景一：防止执行危险的 Shell 命令

这是一个典型的安全防护类 Hook，目的是强制项目的安全规范，避免 Claude 或项目开发者执行危险的 Shell 命令，保护项目资源的安全。

**目标**：配置一个 Hook，在 Claude 执行任何 Bash 命令前进行拦截校验 —— 如果命令中包含 `rm -rf` 或 `rm -r -f` 这类破坏性删除模式，则阻断该命令的执行；否则，允许执行。

**实现步骤**：



1. 确保项目的 `.claude/hooks/` 目录存在；

2. 在 `.claude/hooks/` 目录下创建脚本文件 `block-rm-rf.sh`，内容同 3.2.4 节的示例脚本；

3. 给脚本添加可执行权限：`chmod +x .claude/hooks/block-rm-rf.sh`；

4. 编辑项目级的 `.claude/settings.json` 配置文件，添加如下 Hook 配置：



```
{

&#x20; "hooks": {

&#x20;   "PreToolUse": \[

&#x20;     {

&#x20;       "matcher": "Bash",

&#x20;       "if": "Bash(rm \*)",

&#x20;       "hooks": \[

&#x20;         {

&#x20;           "type": "command",

&#x20;           "command": "bash \\"\$CLAUDE\_PROJECT\_DIR/.claude/hooks/block-rm-rf.sh\\"",

&#x20;           "timeout": 10,

&#x20;           "async": false

&#x20;         }

&#x20;       ]

&#x20;     }

&#x20;   ]

&#x20; }

}
```



1. 启动 Claude CLI，尝试执行任意包含 `rm -rf` 模式的命令，验证 Hook 是否生效。

**预期结果**：当 Claude 尝试执行包含 `rm -rf` 模式的命令时，Hook 脚本会输出自定义的错误信息，Claude 会终止该命令的执行，并将错误信息展示在终端中。

#### 5.4.2 实战场景二：代码提交后自动格式化

这是一个典型的自动化扩展类 Hook，目的是减少手动重复操作，保证项目代码风格的一致性。

**目标**：配置一个 Hook，在 Claude 成功执行文件编辑或写入类工具后，自动调用项目的代码格式化工具（如 Prettier、Black），对修改后的文件进行代码格式化。

**实现步骤**：



1. 确保项目的 `.claude/hooks/` 目录存在；

2. 在 `.claude/hooks/` 目录下创建脚本文件 `auto-format.sh`，写入调用代码格式化工具的逻辑；

3. 给脚本添加可执行权限：`chmod +x .claude/hooks/auto-format.sh`；

4. 编辑项目级的 `.claude/settings.json` 配置文件，添加如下 Hook 配置：



```
{

&#x20; "hooks": {

&#x20;   "PostToolUse": \[

&#x20;     {

&#x20;       "matcher": "Edit|Write|MultiEdit",

&#x20;       "hooks": \[

&#x20;         {

&#x20;           "type": "command",

&#x20;           "command": "bash \\"\$CLAUDE\_PROJECT\_DIR/.claude/hooks/auto-format.sh\\"",

&#x20;           "timeout": 30,

&#x20;           "async": true

&#x20;         }

&#x20;       ]

&#x20;     }

&#x20;   ]

&#x20; }

}
```



1. 重启 Claude CLI，尝试让 Claude 修改项目中的代码文件，验证 Hook 是否生效。

**预期结果**：当 Claude 执行文件编辑或写入操作后，Hook 脚本会自动执行，调用代码格式化工具对修改后的文件进行格式化。由于这个 Hook 脚本是异步执行的，Claude 不会等待格式化完成，会直接继续后续流程。

## 6. 调试与排错

在使用 Hooks 机制时，配置不生效、脚本逻辑被误判、拦截规则不生效、工具执行异常、Hook 无法被触发等是最常见的问题。这类问题大部分都是由配置错误、脚本逻辑错误或环境依赖缺失导致的，可以通过 Claude 的内置调试工具、日志记录功能、脚本输出信息定位并解决。

### 6.1 启用 Hooks 调试日志

Claude CLI 提供了完整的日志记录功能，可以记录所有 Hook 的触发、执行过程和结果信息。这些日志信息是排查 Hook 配置问题的关键依据 —— 如果没有日志信息，将很难定位问题的根源。

#### 6.1.1 查看 Claude 运行日志

Hook 脚本的所有执行日志，都会被 Claude 记录到其运行日志中。可以在启动 Claude CLI 时，增加 `--verbose` 级别的参数，来控制日志的输出详细程度。参数的取值范围和作用如下表所示：



| 参数          | 作用                                    |
| ----------- | ------------------------------------- |
| `--verbose` | 输出详细的调试日志，包括所有 Hook 的加载、匹配、触发和执行结果信息  |
| `--debug`   | 输出更详细的调试日志，包含所有 Hook 的输入、输出和完整的执行链路信息 |

例如，执行 `claude --verbose` 命令启动 Claude，当 Hook 被触发执行时，相关的加载、匹配、触发和执行结果信息，会被直接打印到终端中，便于实时调试和观察整个执行链路。

#### 6.1.2 输出详细的脚本日志

在 Hook 脚本中，可以通过标准错误流（stderr）输出详细的调试日志，记录脚本的执行逻辑、关键参数的解析结果或分支判断逻辑。这些日志信息会被 Claude 捕获，并记录到 Claude 的运行日志中。

例如，在 Bash 脚本中，可以通过 `echo "调试信息：读取到的命令是 $COMMAND" >&2` 语句，将调试信息输出到 stderr；在 Python 脚本中，可以通过 `sys.stderr.write(f"调试信息：读取到的命令是 {command}")` 语句，将调试信息输出到 stderr。

### 6.2 常见问题与解决方法

在开发和使用 Hook 的过程中，可能会遇到各种问题。根据社区的常见问题清单，大部分问题的根源都是配置不正确、脚本没有执行权限、脚本编码不兼容或环境依赖缺失导致的。

#### 6.2.1 问题一：配置了 Hook 规则，但事件触发后脚本没有运行

**可能原因**：配置文件的路径不正确、JSON 格式有误、`matcher` 或 `if` 条件配置错误，或脚本没有可执行权限。

**排查步骤**：



1. 检查配置文件的路径是否正确 —— 必须放在项目根目录下的 `.claude/` 目录中，文件名必须是 `settings.json` 或 `settings.local.json`；

2. 运行 `jq . .claude/settings.json` 命令，验证配置文件的 JSON 格式是否正确 —— 如果格式有误，命令会输出明确的错误提示；

3. 检查配置文件中的 `matcher` 正则表达式和 `if` 条件，确认其能匹配到实际的工具名和参数；

4. 检查 Hook 脚本的权限 —— 在 macOS/Linux 系统上，需要执行 `chmod +x .claude/hooks/*.sh` 命令，给脚本添加可执行权限；

5. 检查 Hook 脚本的头部 "shebang" 行是否正确 —— 例如 Bash 脚本需要以 `#!/bin/bash` 开头，Python 脚本需要以 `#!/usr/bin/env python3` 开头。

#### 6.2.2 问题二：Hook 脚本执行了，但没有按预期拦截操作

**可能原因**：脚本的退出码设置错误，或 stdout 输出的 JSON 格式不符合规范。

**排查步骤**：



1. 检查脚本的退出码设置 —— 阻断类的 Hook 脚本需要返回 exit code 2，才能被 Claude 识别为阻断决策；

2. 检查脚本的 stdout 输出格式 —— 如果脚本输出的是 JSON 字符串，需要保证其格式正确，且包含 `is_approved` 或 `decision` 字段；

3. 验证脚本的逻辑执行结果 —— 可以直接在终端中运行脚本，手动输入测试用的 JSON 内容，检查脚本的退出码和输出是否符合预期；

4. 检查 Hook 配置的 `if` 条件是否过于严格，导致没有匹配到实际的参数。

#### 6.2.3 问题三：Hook 脚本在 Claude 中执行正常，但在终端中直接执行乱码

**可能原因**：脚本的编码格式不是 UTF-8，或环境变量的编码格式不兼容。

**排查步骤**：



1. 检查脚本的编码格式 —— 必须使用 UTF-8 编码；

2. 在脚本的头部添加强制编码设置，或在脚本的开头加入 `export LC_ALL=C.UTF-8` 和 `export LANG=C.UTF-8` 语句，设置脚本的环境变量编码格式；

3. 检查 Claude 的日志编码格式，确认其与终端的编码格式配置一致；

4. 对于 Python 脚本，需要在脚本头部添加 `# -*- coding: utf-8 -*-` 声明，并且在输出 JSON 字符串时，手动将其编码为 UTF-8 格式。

#### 6.2.4 问题四：Hook 脚本执行超时，被 Claude 强制终止

**可能原因**：脚本的执行时间超过了配置文件中 `timeout` 字段设置的超时时间，或脚本执行过程中出现了死锁、无限循环。

**排查步骤**：



1. 检查 Hook 脚本的执行逻辑，确认其没有死锁、无限循环或长时间的阻塞操作；

2. 在配置文件中，调大对应 Hook 规则的 `timeout` 字段值 —— 例如从默认的 60 秒调整为 300 秒；

3. 将 Hook 规则的 `async` 字段设置为 `true`，让脚本在后台异步执行，不阻塞 Claude 的主流程；

4. 检查脚本的依赖是否正常安装，确认脚本的外部依赖（如 jq 工具、网络连接）都正常可用。

#### 6.2.5 问题五：多个 Hook 规则执行时，优先级不符合预期

**可能原因**：配置文件中的 Hook 规则顺序不正确，或多个 Hook 规则的冲突合并规则没有按预期执行。

**排查步骤**：



1. 检查配置文件中的 Hook 规则顺序 —— 同一个事件的多个 Hook 规则，会按照配置中的先后顺序依次执行；

2. 调整 Hook 规则的顺序，将需要优先执行的规则放在前面；

3. 记住决策优先级：deny（阻断）> ask（询问）> allow（放行）；

4. 对于有依赖关系的 Hook 规则，将被依赖的规则放在前面执行。

### 6.3 调试技巧

在实际开发 Hook 脚本时，可以使用以下几个实用技巧，简化调试过程，提升排错效率。



* **利用占位符输出完整输入**：Claude 提供了一个 `$ARGUMENTS` 占位符，可以将其配置在 Hook 的 `command` 字段中，将 Claude 发送给脚本的完整输入 JSON 内容，输出到 stderr 或一个临时日志文件中 —— 这可以帮助你验证脚本接收的输入 JSON 结构是否正确，提取的参数内容是否符合预期；

* **在终端中手动独立测试脚本**：在终端中直接执行 Hook 脚本，手动输入测试用的 JSON 内容，模拟 Claude 传递给脚本的输入数据，检查脚本的退出码、stdout 输出和 stderr 信息是否符合预期 —— 这是隔离排查脚本逻辑问题的最有效方法；

* **使用简单的命令替代脚本验证配置**：在调试时，可以先将 Hook 的 `command` 字段设置为一个简单的测试命令，例如 `echo "$ARGUMENTS" >> ~/hook-debug.log`—— 这个命令会将 Claude 发送的完整输入 JSON 内容，直接写到一个临时文件中。如果这个测试命令能正常执行，说明 Hook 的配置是正确的，问题出在脚本的逻辑上；

* **逐步增加脚本逻辑复杂度**：先编写一个最简单的脚本，验证 Hook 的配置和触发逻辑是否正常，再逐步增加脚本的复杂逻辑，如参数解析、条件判断、外部命令调用等 —— 这可以帮助你快速定位到是哪一部分的逻辑出现了问题；

* **使用轻量的日志输出方式**：在脚本中，可以将关键的执行步骤、参数值或分支判断结果，输出到一个自定义的日志文件中 —— 例如在用户的主目录下创建一个 `.claude/hooks/debug.log` 文件，将脚本的所有调试信息都追加到该文件中。这可以帮助你复盘脚本的完整执行流程，快速定位到问题的根源。

## 7. 结论

Claude CLI 的 Hooks 机制，是将 AI 辅助编程从 "建议性指导" 升级为 "确定性工程化流程" 的关键核心技术。通过在 Claude 生命周期的关键事件节点上挂载自定义脚本，开发者可以实现对 Claude 行为的细粒度控制 —— 这不仅能极大地提升项目的安全性、代码质量和团队工作流的一致性，还能将大量重复性的工作流操作自动化，显著提升研发效率，让 Claude 的使用场景从个人本地开发扩展到团队协作和生产级 CI/CD 流程中。

### 7.1 最佳实践建议

根据官方文档和社区的大量落地案例，在实际使用 Hooks 机制时，遵循以下工程化最佳实践，可以提升配置的可维护性、兼容性和执行效率。



* **优先使用官方或社区的 Hook 插件**：优先选择官方维护的插件，或社区中经过大量项目验证的成熟 Hook 插件 —— 这些插件已经完成了多场景兼容测试，覆盖了安全防护、代码质量、工作流优化等高频典型场景，无需从零开发。

* **Keep It Simple, Stupid**：Hook 脚本的逻辑应该尽可能简单 —— 同步执行的 Hook 逻辑应控制在 10 行代码以内，避免在脚本中执行复杂的逻辑、调用大量外部依赖，或进行长时间的网络请求，导致 Claude 的主流程被长时间阻塞。

* **脚本无侵入性与退出码规范**：脚本应该保持无状态，不依赖任何外部的环境变量或绝对路径，所有的临时文件都应该输出到系统的临时目录中；同时，必须严格遵守退出码的使用规范：返回 0 表示验证通过，返回 2 表示阻断操作，返回其他非 0 码表示脚本执行异常。

* **必须做的输入校验与参数转义**：Hook 脚本必须对从 stdin 中读取的输入 JSON 内容进行严格的校验，过滤掉非法的参数值或格式错误的内容；在拼 Shell 命令参数时，必须对所有的参数值进行转义，避免被注入攻击。

* **精准匹配，避免过度触发**：Hook 规则应该尽可能精准地匹配工具名和参数，避免使用 `*` 作为 `matcher` 或 `if` 条件的匹配规则，导致 Hook 被无意义的事件频繁触发。

* **多环境测试验证**：在开发完 Hook 脚本后，需要在 Windows、macOS、Linux 等主流操作系统上，以及不同类型的终端环境下，对脚本进行完整的验证测试 —— 确保脚本在所有目标环境下，都能按预期的逻辑执行，且不会出现编码错误、路径错误、权限错误等兼容性问题。

* **对配置文件进行版本化管理**：将项目级的 `.claude/settings.json` 配置文件提交到 Git 仓库中，进行版本化管理 —— 这可以保证团队内所有成员的 Hook 配置规则完全一致，避免因配置差异导致的规则执行差异或本地环境开发问题。

* **个人配置必须 Git 忽略**：在 `settings.local.json` 文件中，可以配置个人本地的 Hook 规则来覆盖项目级的默认规则 —— 但需要将该文件添加到项目的 `.gitignore` 文件中，避免将个人配置提交到 Git 仓库中。

### 7.2 延伸阅读

可以参考以下官方资源和社区资源，来深入学习 Hooks 机制的高级用法，或获取更多生产级的 Hook 实战案例。



* 官方文档：Claude CLI 官方教程中的 [Hook 功能集成与进阶调度](https://docs.anthropic.com/claude/docs/hooks-and-functions) 章节；

* 官方插件仓库：由 Anthropic 官方维护的 [Claude 插件市场](https://docs.anthropic.com/claude/plugins/)，其中包含了大量生产级的 Hook 插件；

* 社区的 Hook 集合仓库：由社区维护的 [claude-hook-cookbook](https://github.com/echo-lumen/claude-hook-cookbook)，包含了 9 个可直接在生产环境中使用的 Hook 脚本；

* 官方博客：Anthropic 官方博客上的 [Claude Hooks 配置指南](https://www.anthropic.com/news/claude-hooks-in-practice) 文章，其中介绍了多个实际场景的配置案例；

* 社区的最佳实践指南：由社区整理的 [Claude Hooks 生产级配置示例](https://github.com/topics/claude-hooks)，其中包含了大量经过项目验证的配置规则。

通过本文的系统学习，相信你已经掌握了 Claude CLI Hooks 机制的核心原理与使用方法。如果在实际操作中遇到问题，可以优先查阅的官方文档，或在社区的 GitHub 仓库中搜 issues 里的常见问题，也可以参考其他开发者开源的 Hook 配置案例进行调试。

**参考资料&#x20;**

\[1] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[2] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[3] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://aicoding.juejin.cn/post/7647909099690000418](https://aicoding.juejin.cn/post/7647909099690000418)

\[4] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[5] Claude Code Hooks 从入门到实战(附安全检查+代码质量+Git工作流脚本)-51CTO.COM[ https://www.51cto.com/article/829071.html](https://www.51cto.com/article/829071.html)

\[6] Claude Code Hooks 完全指南:事件机制、决策系统与插件实战-51CTO.COM[ https://www.51cto.com/article/844800.html](https://www.51cto.com/article/844800.html)

\[7] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[8] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://aicoding.juejin.cn/post/7642623843019128841](https://aicoding.juejin.cn/post/7642623843019128841)

\[9] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[10] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[11] Claude Code Hooks 完整可粘贴 settings.json:12 个生产级 hook + 3 真实事故救场 - 掘金[ https://juejin.cn/post/7645097761030275078](https://juejin.cn/post/7645097761030275078)

\[12] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[13] Hooks才是Claude Code CLI 的革命性更新前言 前面对Claude Code CLI有了基本了解，今天继 - 掘金[ https://juejin.cn/post/7561745236940423203](https://juejin.cn/post/7561745236940423203)

\[14] 别每次重复配置了!CLAUDE.md + Hooks 让 Claude Code 开箱就记住你的规则Claude Cod - 掘金[ https://juejin.cn/post/7646622735791767562](https://juejin.cn/post/7646622735791767562)

\[15] Claude Code Skills+Hooks+Subagents 从入门到精通，一步到位上周五晚上11点，我正准备下 - 掘金[ https://juejin.cn/post/7633262208111345698](https://juejin.cn/post/7633262208111345698)

\[16] Claude Code Hooks 超详细教程，附源码Claude Code Hooks 超详细教程，附源码 上周五晚上 - 掘金[ https://juejin.cn/post/7632518581080408104](https://juejin.cn/post/7632518581080408104)

\[17] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[18] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[19] ⚡精通Claude第6课-Hooks钩子系统:从前端视角玩转AI自动化工作流作为前端开发者，我们对"钩子"这个词再熟悉不 - 掘金[ https://juejin.cn/post/7632264201230991394](https://juejin.cn/post/7632264201230991394)

\[20] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[21] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://aicoding.juejin.cn/post/7642623843019128841](https://aicoding.juejin.cn/post/7642623843019128841)

\[22] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[23] Claude Code Hooks 详解和使用-51CTO.COM[ https://www.51cto.com/article/847419.html](https://www.51cto.com/article/847419.html)

\[24] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[25] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[26] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[27] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[28] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://aicoding.juejin.cn/post/7642623843019128841](https://aicoding.juejin.cn/post/7642623843019128841)

\[29] ⚡精通Claude第6课-Hooks钩子系统:从前端视角玩转AI自动化工作流作为前端开发者，我们对"钩子"这个词再熟悉不 - 掘金[ https://juejin.cn/post/7632264201230991394](https://juejin.cn/post/7632264201230991394)

\[30] Hooks : 事件、handler 和执行语义 - claude\_0x07Hook 是 Claude Code 的感觉 - 掘金[ https://juejin.cn/post/7636343113468936226](https://juejin.cn/post/7636343113468936226)

\[31] Claude Code Hooks 完全指南:事件机制、决策系统与插件实战-51CTO.COM[ https://www.51cto.com/article/844800.html](https://www.51cto.com/article/844800.html)

\[32] Claude Code Hooks 详解和使用-51CTO.COM[ https://www.51cto.com/article/847419.html](https://www.51cto.com/article/847419.html)

\[33] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[34] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[35] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://juejin.cn/post/7642623843019128841](https://juejin.cn/post/7642623843019128841)

\[36] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[37] Untitled[ https://unpkg.com/@gguf/claw@2026.2.20/docs/gateway/cli-backends.md](https://unpkg.com/@gguf/claw@2026.2.20/docs/gateway/cli-backends.md)

\[38] Claude Code Hooks 详解和使用-51CTO.COM[ https://www.51cto.com/article/847419.html](https://www.51cto.com/article/847419.html)

\[39] Claude Code 通关手册:打造 AI 自动化流水线，Hooks、Skills、Plugins 实战-51CTO.COM[ https://www.51cto.com/article/837052.html](https://www.51cto.com/article/837052.html)

\[40] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[41] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[42] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[43] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[44] 别再什么都塞进 CLAUDE.md 了——Anthropic 官方发布的七种自定义方式决策框架\_人人都是产品经理[ http://m.toutiao.com/group/7653321298067718671/](http://m.toutiao.com/group/7653321298067718671/)

\[45] 一天一个开源项目(第106篇):Claude Plugins Official - Anthropic 官方 Claude Code 插件生态全解析 - 掘金[ https://juejin.cn/post/7641743586414313481](https://juejin.cn/post/7641743586414313481)

\[46] Hooks才是Claude Code CLI 的革命性更新前言 前面对Claude Code CLI有了基本了解，今天继 - 掘金[ https://juejin.cn/post/7561745236940423203](https://juejin.cn/post/7561745236940423203)

\[47] 别每次重复配置了!CLAUDE.md + Hooks 让 Claude Code 开箱就记住你的规则Claude Cod - 掘金[ https://juejin.cn/post/7646622735791767562](https://juejin.cn/post/7646622735791767562)

\[48] 一、扩展 Claude Code:开篇Claude Code CLI 是一个强大的 AI 编程助手，但它的真正威力在于可 - 掘金[ https://juejin.cn/post/7640289667234103315](https://juejin.cn/post/7640289667234103315)

\[49] 一天一个开源项目(第106篇):Claude Plugins Official - Anthropic 官方 Claude Code 插件生态全解析 - 掘金[ https://juejin.cn/post/7641743586414313481](https://juejin.cn/post/7641743586414313481)

\[50] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[51] 剑客精翻:Claude Code官方教程(06)-GitHub集成与钩子功能详解\_工作\_配置\_代码[ https://m.sohu.com/a/933118621\_122042668/](https://m.sohu.com/a/933118621_122042668/)

\[52] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[53] Claude Code Hooks 完整可粘贴 settings.json:12 个生产级 hook + 3 真实事故救场 - 掘金[ https://juejin.cn/post/7645097761030275078](https://juejin.cn/post/7645097761030275078)

\[54] Claude Code Hooks 从入门到实战(附安全检查+代码质量+Git工作流脚本)-51CTO.COM[ https://www.51cto.com/article/829071.html](https://www.51cto.com/article/829071.html)

\[55] AI 编程工程化:Hook——AI 每次操作前后的自动检查站本文介绍 AI 编程工程化中的 Hook 机制，通过在 AI - 掘金[ https://juejin.cn/post/7616943516188131328](https://juejin.cn/post/7616943516188131328)

\[56] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[57] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[58] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[59] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[60] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://aicoding.juejin.cn/post/7642623843019128841](https://aicoding.juejin.cn/post/7642623843019128841)

\[61] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[62] Untitled[ https://unpkg.com/@gguf/claw@2026.2.5/docs/cli/hooks.md](https://unpkg.com/@gguf/claw@2026.2.5/docs/cli/hooks.md)

\[63] Untitled[ https://unpkg.com/@gguf/claw@2026.2.20/docs/gateway/cli-backends.md](https://unpkg.com/@gguf/claw@2026.2.20/docs/gateway/cli-backends.md)

\[64] Hooks : 事件、handler 和执行语义 - claude\_0x07Hook 是 Claude Code 的感觉 - 掘金[ https://juejin.cn/post/7636343113468936226](https://juejin.cn/post/7636343113468936226)

\[65] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[66] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[67] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[68] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://aicoding.juejin.cn/post/7642623843019128841](https://aicoding.juejin.cn/post/7642623843019128841)

\[69] Hooks : 事件、handler 和执行语义 - claude\_0x07Hook 是 Claude Code 的感觉 - 掘金[ https://juejin.cn/post/7636343113468936226](https://juejin.cn/post/7636343113468936226)

\[70] Untitled[ https://unpkg.com/@gguf/claw@2026.2.20/docs/gateway/cli-backends.md](https://unpkg.com/@gguf/claw@2026.2.20/docs/gateway/cli-backends.md)

\[71] 深入理解 Claude Code:从 CLAUDE.md 到 Hooks、Skills、Subagents..\_人人都是产品经理[ http://m.toutiao.com/group/7654137837872251444/](http://m.toutiao.com/group/7654137837872251444/)

\[72] Claude Code Hooks 详解和使用-51CTO.COM[ https://www.51cto.com/article/847419.html](https://www.51cto.com/article/847419.html)

\[73] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[74] Claude Code Hooks 完全指南:事件机制、决策系统与插件实战-51CTO.COM[ https://www.51cto.com/article/844800.html](https://www.51cto.com/article/844800.html)

\[75] Claude Code Hooks:给 AI 助手装上"安全带"AI 很能干，但它不懂你项目里的规矩——哪些命令不能跑、 - 掘金[ https://aicoding.juejin.cn/post/7648862178301542435](https://aicoding.juejin.cn/post/7648862178301542435)

\[76] Claude Code Hooks 2026 完整实战指南:六个生产可用的 Hook 场景，附完整脚本和配置-51CTO.COM[ https://www.51cto.com/article/840703.html](https://www.51cto.com/article/840703.html)

\[77] Claude Code 的 Hooks 系统Hooks 是用户自定义的 shell 命令、HTTP 端点、LLM 提示词 - 掘金[ https://juejin.cn/post/7636653992588247075](https://juejin.cn/post/7636653992588247075)

\[78] Hooks : 事件、handler 和执行语义 - claude\_0x07Hook 是 Claude Code 的感觉 - 掘金[ https://juejin.cn/post/7636343113468936226](https://juejin.cn/post/7636343113468936226)

\[79] 剑客精翻:Claude Code官方教程(06)-GitHub集成与钩子功能详解\_工作\_配置\_代码[ https://m.sohu.com/a/933118621\_122042668/](https://m.sohu.com/a/933118621_122042668/)

\[80] Plugin 扩展实战:增强 Claude Code 的能力深入讲解 Claude Code 的 Plugin 系统,包 - 掘金[ https://juejin.cn/post/7608512654684946441](https://juejin.cn/post/7608512654684946441)

\[81] Claude Code CLI 完整命令参考手册Claude Code CLI 完整命令参考手册 目录 一、CLI 命令 - 掘金[ https://juejin.cn/post/7649971464453193791](https://juejin.cn/post/7649971464453193791)

\[82] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[83] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[84] Untitled[ https://unpkg.com/@gguf/claw@2026.2.5/docs/cli/hooks.md](https://unpkg.com/@gguf/claw@2026.2.5/docs/cli/hooks.md)

\[85] Claude Code 生命周期 Hooks 使用指南概述 Hooks 是用户自定义的脚本/命令，在 Claude Co - 掘金[ https://aicoding.juejin.cn/post/7646996673108951092](https://aicoding.juejin.cn/post/7646996673108951092)

\[86] Claude Code Hooks 详解和使用-51CTO.COM[ https://www.51cto.com/article/847419.html](https://www.51cto.com/article/847419.html)

\[87] 万字深度解析Claude Code的hook系统:让AI编程更智能、更可控|上篇—详解篇深度解析Claude Code的 - 掘金[ https://juejin.cn/post/7549389760323174451](https://juejin.cn/post/7549389760323174451)

\[88] Claude Code 进阶使用:Subagents、第三方插件、Hooks、记忆与工作流Claude Code 进阶使 - 掘金[ https://juejin.cn/post/7634396066285699082](https://juejin.cn/post/7634396066285699082)

\[89] Claude Code Hooks 完全指南源码路径: src/utils/hooks.ts(执行引擎)、src/sch - 掘金[ https://juejin.cn/post/7647909099690000418](https://juejin.cn/post/7647909099690000418)

\[90] 新手上路(五):Claude Code Hooks 深度实战:6 大生命周期事件 × 10 个生产级自动化规则 × 5 种处理器类型 - 掘金[ https://juejin.cn/post/7634480263964819483](https://juejin.cn/post/7634480263964819483)

\[91] ⚡精通Claude第6课-Hooks钩子系统:从前端视角玩转AI自动化工作流作为前端开发者，我们对"钩子"这个词再熟悉不 - 掘金[ https://juejin.cn/post/7632264201230991394](https://juejin.cn/post/7632264201230991394)

\[92] 【Claude基础】06.Hooks深度指南:事件驱动的自动化管道--- ## 1\\. Hooks 设计哲学 Claud - 掘金[ https://juejin.cn/post/7642623843019128841](https://juejin.cn/post/7642623843019128841)

\[93] Claude Code Hooks 2026 完整实战指南:六个生产可用的 Hook 场景，附完整脚本和配置-51CTO.COM[ https://www.51cto.com/article/840703.html](https://www.51cto.com/article/840703.html)

\[94] Claude Code Hooks 详解和使用-51CTO.COM[ https://www.51cto.com/article/847419.html](https://www.51cto.com/article/847419.html)

\[95] Hooks才是Claude Code CLI 的革命性更新前言 前面对Claude Code CLI有了基本了解，今天继 - 掘金[ https://juejin.cn/post/7561745236940423203](https://juejin.cn/post/7561745236940423203)

\[96] Claude code:Hooks很多人用 Claude Code 时，都想实现一些自定义功能:自动记录所有执行的命令、 - 掘金[ https://aicoding.juejin.cn/post/7650847475419758628](https://aicoding.juejin.cn/post/7650847475419758628)

> （注：文档部分内容可能由 AI 生成）