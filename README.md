# Push-Files-to-Repo

一个通过 **Pull Request** 将文件或文件夹从一个仓库推送到另一个仓库的 GitHub Action。

## 功能特性

- 📁 复制指定文件或整个文件夹到另一个仓库
- 🔀 通过创建 Pull Request（而非直接推送）进行代码审查
- 🧹 可选在复制前清理目标文件夹
- 📝 可配置提交信息、PR 标题和描述
- 🔒 支持 PAT 和 GitHub App Token 认证
- 📋 支持创建草稿 PR

## 快速开始

```yaml
name: 推送文件到另一个仓库

on:
  push:
    branches: [main]

jobs:
  push-files:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: NEVSTOP-LAB/Push-Files-to-Repo@main
        with:
          source_folder: 'docs/'
          destination_repo: 'my-org/my-other-repo'
          destination_folder: 'imported-docs/'
          token: ${{ secrets.PAT }}
```

## 输入参数

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `source_folder` | ✅ | – | 源文件或文件夹路径（相对于仓库根目录） |
| `destination_repo` | ✅ | – | 目标仓库，格式为 `owner/repo` |
| `destination_folder` | ❌ | `.` | 目标仓库中的存放路径 |
| `destination_base_branch` | ❌ | `main` | 创建 PR 的目标基础分支 |
| `destination_head_branch` | ❌ | 自动生成 | PR 的分支名称 |
| `token` | ✅ | – | 具有目标仓库访问权限的 PAT 或 GitHub App Token |
| `commit_message` | ❌ | `chore: push files from source repository` | 提交信息 |
| `pr_title` | ❌ | `[Automated] Push files from source repository` | PR 标题 |
| `pr_body` | ❌ | 自动生成 | PR 描述 |
| `git_user_name` | ❌ | `github-actions[bot]` | Git 提交者名称 |
| `git_user_email` | ❌ | `41898282+github-actions[bot]@users.noreply.github.com` | Git 提交者邮箱 |
| `cleanup` | ❌ | `false` | 复制前是否删除目标文件夹中的已有文件 |
| `draft` | ❌ | `false` | 是否创建草稿 PR |

## 输出参数

| 输出 | 说明 |
|------|------|
| `pr_number` | 创建的 Pull Request 编号 |
| `pr_url` | 创建的 Pull Request URL |

## 认证方式

此 Action 需要一个具有**目标仓库**访问权限的 Token。默认的 `GITHUB_TOKEN` 仅能访问当前仓库，**无法**用于跨仓库操作。

### 方式一：细粒度个人访问令牌（个人使用推荐）

1. 进入 **GitHub Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens**
2. 点击 **Generate new token**
3. 在 **Repository access** 下选择目标仓库
4. 设置权限：
   - `Contents`：**Read and write**
   - `Pull requests`：**Read and write**
5. 将 Token 保存为仓库 Secret（例如 `PAT`）

### 方式二：GitHub App Token（组织使用推荐）

1. 创建一个 GitHub App，设置以下仓库权限：
   - `Contents`：**Read and write**
   - `Pull requests`：**Read and write**
2. 将该 App 安装到目标仓库
3. 使用 [actions/create-github-app-token](https://github.com/actions/create-github-app-token) 生成 Token：

```yaml
- uses: actions/create-github-app-token@v2
  id: app-token
  with:
    app-id: ${{ secrets.APP_ID }}
    private-key: ${{ secrets.APP_PRIVATE_KEY }}
    owner: target-owner
    repositories: target-repo

- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'dist/'
    destination_repo: 'target-owner/target-repo'
    token: ${{ steps.app-token.outputs.token }}
```

## 使用示例

### 推送文件夹

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'build/output'
    destination_repo: 'my-org/website'
    destination_folder: 'static/assets'
    token: ${{ secrets.PAT }}
```

### 推送单个文件

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'config/settings.json'
    destination_repo: 'my-org/config-repo'
    destination_folder: 'apps/myapp'
    token: ${{ secrets.PAT }}
```

### 复制前清理目标文件夹

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'generated-docs/'
    destination_repo: 'my-org/docs-repo'
    destination_folder: 'api-docs/'
    cleanup: 'true'
    token: ${{ secrets.PAT }}
```

### 自定义提交信息和 PR 详情

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'src/shared'
    destination_repo: 'my-org/shared-lib'
    destination_folder: 'src'
    commit_message: 'feat: sync shared components from main repo'
    pr_title: 'Sync shared components'
    pr_body: |
      Automated sync of shared components.
      Source: ${{ github.repository }}@${{ github.sha }}
    token: ${{ secrets.PAT }}
```

### 创建草稿 PR

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'dist/'
    destination_repo: 'my-org/release-repo'
    draft: 'true'
    token: ${{ secrets.PAT }}
```

### 使用 PR 输出

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  id: push
  with:
    source_folder: 'docs/'
    destination_repo: 'my-org/docs'
    token: ${{ secrets.PAT }}

- run: |
    echo "PR #${{ steps.push.outputs.pr_number }}"
    echo "URL: ${{ steps.push.outputs.pr_url }}"
```

## 工作原理

1. **校验**所有必填输入参数，检查源路径是否存在
2. **克隆**目标仓库（浅克隆基础分支）
3. **创建**目标仓库中的新分支
4. **提交**并**推送**变更
5. 通过 GitHub REST API **创建** Pull Request
6. **输出** PR 编号和 URL

## 设计文档

详细的研究和设计文档请参阅 [docs/design.md](docs/design.md)，包括：
- 认证方式对比
- API 使用详情
- 安全性考虑
- 架构概览

## 许可证

MIT