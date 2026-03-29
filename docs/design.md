# 研究与设计文档

## Push-Files-to-Repo GitHub Action

### 1. 概述

本文档记录了 **Push-Files-to-Repo** GitHub Action 的研究与设计过程。该 Action 将源 GitHub 仓库中的文件（或文件夹）复制并通过 Pull Request 提交到目标 GitHub 仓库。

---

### 2. 调研

#### 2.1 现有方案

| Action | 实现方式 | 局限性 |
|--------|----------|--------|
| [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request) | 功能完整的 PR 创建（支持同仓库和跨仓库） | 依赖较重；主要针对同仓库变更设计 |
| [cpina/github-action-push-to-another-repository](https://github.com/cpina/github-action-push-to-another-repository) | 直接推送（非 PR 方式） | 无 PR 工作流 – 直接推送到分支 |
| [actions/checkout](https://github.com/actions/checkout) | 官方 checkout action | 仅作为基础组件 – 不提供 PR 创建功能 |

**结论**：目前没有轻量级的 Action 能在一步操作中同时实现"复制指定文件/文件夹" + "在另一个仓库创建 PR"。本 Action 填补了这一空白。

#### 2.2 认证与权限

跨仓库操作**无法**使用默认的 `GITHUB_TOKEN`，因为它仅限于当前仓库。以下是评估的三种认证方式：

| 方式 | 跨仓库 | 粒度 | 触发工作流 | 配置复杂度 |
|------|--------|------|-----------|-----------|
| `GITHUB_TOKEN` | ❌ 否 | 仓库级别 | ❌ 否 | ✅ 无需配置 |
| 经典 PAT | ✅ 是 | ❌ 所有仓库 | ✅ 是 | ✅ 简单 |
| 细粒度 PAT | ✅ 是 | ✅ 按仓库 | ✅ 是 | ✅ 中等 |
| GitHub App Token | ✅ 是 | ✅ 按仓库 | ✅ 是 | ❌ 复杂 |

**建议**：
- **开发/个人使用**：使用细粒度 PAT，在目标仓库上设置 `Contents: Read & Write` 和 `Pull Requests: Read & Write` 权限。
- **生产/组织使用**：通过 [actions/create-github-app-token](https://github.com/actions/create-github-app-token) 使用 GitHub App Token。

##### 所需 Token 权限

| 权限 | 范围 | 原因 |
|------|------|------|
| `Contents` | Read & Write | 克隆仓库、创建分支、推送提交 |
| `Pull Requests` | Read & Write | 通过 API 创建 Pull Request |
| `Workflows` | Read & Write | 仅在 PR 修改 `.github/workflows/` 文件时需要 |

##### 如何创建细粒度 PAT

1. 进入 **GitHub Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens**
2. 点击 **Generate new token**
3. 设置 Token 名称、过期时间和描述
4. 在 **Repository access** 下选择 **Only select repositories** 并选择目标仓库
5. 在 **Permissions → Repository permissions** 下：
   - `Contents`：**Read and write**
   - `Pull requests`：**Read and write**
6. 点击 **Generate token** 并将其保存为仓库 Secret

##### 如何使用 GitHub App Token

1. 创建一个 GitHub App，设置上述权限
2. 将该 App 安装到目标仓库
3. 将 App ID 和私钥保存为 Secret
4. 在工作流中使用 `actions/create-github-app-token@v2` 生成 Token

```yaml
- uses: actions/create-github-app-token@v2
  id: app-token
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    owner: target-owner
    repositories: target-repo
```

#### 2.3 创建 Pull Request 的 GitHub API

使用 [创建 Pull Request](https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request) 接口：

```
POST /repos/{owner}/{repo}/pulls
```

**必填字段**：
- `title` – PR 标题
- `head` – 源分支名称
- `base` – 目标分支名称
- `body` – PR 描述

**可选字段**：
- `draft` – 布尔值，是否创建草稿 PR

**错误处理**：
- `422` 且消息为 "A pull request already exists" – 幂等处理
- `404` – 仓库未找到或 Token 无权访问
- `403` – 权限不足

#### 2.4 Git 操作

本 Action 使用标准的 git CLI 命令：

1. `git clone --depth=1` – 浅克隆以提高效率
2. `git checkout -b` – 创建新分支
3. `git add -A` – 暂存所有变更
4. `git diff --cached --quiet` – 检测是否有实际变更
5. `git commit` – 使用可配置的提交信息进行提交
6. `git push` – 推送分支到远程

git 操作的认证使用 `http.extraheader` 方式：
```
git -c "http.extraheader=Authorization: Basic <base64>" clone ...
```

#### 2.5 安全性考虑

1. **Token 保护**：使用 `::add-mask::` 注册 Token 和派生的认证头，确保它们不会出现在日志中。
2. **不在 URL 中嵌入 Token**：使用 `http.extraheader` 传递凭据，避免 Token 泄露到远程 URL、git 配置或错误信息中。
3. **输出过滤**：clone 日志输出会过滤掉可能的凭据残留。
4. **临时目录清理**：使用 `trap cleanup EXIT` 确保临时目录被移除，且在删除前清理 git 配置中的凭据。
5. **输入校验**：所有必填输入在 git 操作之前进行校验。

---

### 3. 设计

#### 3.1 架构

```
┌─────────────────────────────────────────────────────┐
│  GitHub Actions 工作流（源仓库）                       │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  Push-Files-to-Repo Action                    │  │
│  │                                               │  │
│  │  1. 校验输入参数                                │  │
│  │  2. 解析源文件/文件夹路径                         │  │
│  │  3. 克隆目标仓库（浅克隆，基础分支）               │  │
│  │  4. 创建 head 分支                              │  │
│  │  5. 从源复制文件到目标                            │  │
│  │  6. 提交并推送变更                               │  │
│  │  7. 通过 GitHub REST API 创建 PR               │  │
│  │  8. 输出 PR 编号和 URL                          │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
└─────────────────────────────────────────────────────┘
          │                           │
          ▼                           ▼
  ┌──────────────┐           ┌──────────────────┐
  │ 源仓库       │           │ 目标仓库          │
  │ （文件）     │           │ （创建 PR）       │
  └──────────────┘           └──────────────────┘
```

#### 3.2 Action 类型：Composite

本 Action 以 **composite action**（`runs: using: composite`）实现，使用 bash 入口脚本。理由：

- **无需构建步骤** – 与 JavaScript action 不同，无需编译或打包
- **可移植** – bash 在所有 GitHub 托管的 runner 上可用
- **依赖项** – 仅依赖 `git`、`curl`、`jq`（均已预装在 runner 上）
- **易维护** – 单个 shell 脚本，便于阅读和调试

#### 3.3 输入/输出设计

**输入参数**（完整详情请参阅 `action.yml`）：

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `source_folder` | ✅ | – | 源文件/文件夹路径 |
| `destination_repo` | ✅ | – | 目标仓库（`owner/repo`） |
| `destination_folder` | ❌ | `.` | 仓库中的目标路径 |
| `destination_base_branch` | ❌ | `main` | PR 的基础分支 |
| `destination_head_branch` | ❌ | 自动生成 | PR 的分支名称 |
| `token` | ✅ | – | PAT 或 App Token |
| `commit_message` | ❌ | 自动 | 提交信息 |
| `pr_title` | ❌ | 自动 | PR 标题 |
| `pr_body` | ❌ | 自动 | PR 描述 |
| `git_user_name` | ❌ | `github-actions[bot]` | 提交者名称 |
| `git_user_email` | ❌ | bot 邮箱 | 提交者邮箱 |
| `cleanup` | ❌ | `false` | 是否先删除已有文件 |
| `draft` | ❌ | `false` | 是否创建草稿 PR |

**输出参数**：

| 输出 | 说明 |
|------|------|
| `pr_number` | PR 编号 |
| `pr_url` | PR URL |

#### 3.4 错误处理

| 场景 | 行为 |
|------|------|
| 缺少必填输入 | 输出错误信息并退出 |
| 源路径不存在 | 输出错误并退出 |
| `destination_repo` 格式无效 | 输出错误并退出 |
| 未检测到变更 | 输出警告 + 跳过 PR 创建 |
| 该分支已存在 PR | 输出警告 + 返回已有 PR 信息 |
| API 调用失败 | 输出 HTTP 状态码和错误内容并退出 |

#### 3.5 分支命名

当未指定 `destination_head_branch` 时，Action 会生成唯一的分支名称：

```
push-files/YYYYMMDD-HHMMSS-RANDOM
```

这样可以避免 Action 多次运行时的冲突。

---

### 4. 测试策略

测试分为：

1. **单元测试**（`tests/test_entrypoint.sh`） – 在模拟环境中独立测试各个函数
2. **集成测试工作流**（`.github/workflows/test.yml`） – 在真实的 GitHub Actions 环境中进行端到端测试

详细实现请参阅 `tests/` 目录。

---

### 5. 参考资料

- [GitHub Actions：创建 composite action](https://docs.github.com/en/actions/sharing-automations/creating-actions/creating-a-composite-action)
- [GitHub REST API：创建 Pull Request](https://docs.github.com/en/rest/pulls/pulls#create-a-pull-request)
- [GitHub：管理个人访问令牌](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [GitHub：创建 GitHub App](https://docs.github.com/en/apps/creating-github-apps)
- [peter-evans/create-pull-request](https://github.com/peter-evans/create-pull-request)
- [actions/checkout](https://github.com/actions/checkout)
