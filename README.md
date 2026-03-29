# Push-Files-to-Repo

A GitHub Action that pushes files or folders from one repository to another via **Pull Request**.

## Features

- 📁 Copy specific files or entire folders to another repository
- 🔀 Creates a Pull Request (not a direct push) for review
- 🧹 Optional cleanup of destination folder before copying
- 📝 Configurable commit messages, PR title, and description
- 🔒 Supports PAT and GitHub App tokens for authentication
- 📋 Draft PR support

## Quick Start

```yaml
name: Push files to another repo

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

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `source_folder` | ✅ | – | Path to the source file or folder (relative to repo root) |
| `destination_repo` | ✅ | – | Target repository in `owner/repo` format |
| `destination_folder` | ❌ | `.` | Target path in the destination repository |
| `destination_base_branch` | ❌ | `main` | Base branch to create the PR against |
| `destination_head_branch` | ❌ | auto-generated | Branch name for the PR |
| `token` | ✅ | – | PAT or GitHub App token with repo access |
| `commit_message` | ❌ | `chore: push files from source repository` | Commit message |
| `pr_title` | ❌ | `[Automated] Push files from source repository` | PR title |
| `pr_body` | ❌ | auto | PR description |
| `git_user_name` | ❌ | `github-actions[bot]` | Git committer name |
| `git_user_email` | ❌ | `41898282+github-actions[bot]@users.noreply.github.com` | Git committer email |
| `cleanup` | ❌ | `false` | Remove existing files in destination folder before copy |
| `draft` | ❌ | `false` | Create the PR as a draft |

## Outputs

| Output | Description |
|--------|-------------|
| `pr_number` | Number of the created Pull Request |
| `pr_url` | URL of the created Pull Request |

## Authentication

This action requires a token with access to the **target repository**. The default `GITHUB_TOKEN` only has access to the current repository and **cannot** be used for cross-repo operations.

### Option 1: Fine-grained Personal Access Token (Recommended for personal use)

1. Go to **GitHub Settings → Developer Settings → Personal Access Tokens → Fine-grained tokens**
2. Click **Generate new token**
3. Under **Repository access**, select the target repository
4. Set permissions:
   - `Contents`: **Read and write**
   - `Pull requests`: **Read and write**
5. Save the token as a repository secret (e.g., `PAT`)

### Option 2: GitHub App Token (Recommended for organizations)

1. Create a GitHub App with these repository permissions:
   - `Contents`: **Read and write**
   - `Pull requests`: **Read and write**
2. Install the app on the target repository
3. Use [actions/create-github-app-token](https://github.com/actions/create-github-app-token) to generate a token:

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

## Examples

### Push a folder

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'build/output'
    destination_repo: 'my-org/website'
    destination_folder: 'static/assets'
    token: ${{ secrets.PAT }}
```

### Push a single file

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'config/settings.json'
    destination_repo: 'my-org/config-repo'
    destination_folder: 'apps/myapp'
    token: ${{ secrets.PAT }}
```

### Clean destination before copy

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'generated-docs/'
    destination_repo: 'my-org/docs-repo'
    destination_folder: 'api-docs/'
    cleanup: 'true'
    token: ${{ secrets.PAT }}
```

### Custom commit message and PR details

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

### Create a draft PR

```yaml
- uses: NEVSTOP-LAB/Push-Files-to-Repo@main
  with:
    source_folder: 'dist/'
    destination_repo: 'my-org/release-repo'
    draft: 'true'
    token: ${{ secrets.PAT }}
```

### Use PR outputs

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

## How It Works

1. **Validates** all required inputs and checks the source path exists
2. **Clones** the target repository (shallow clone of the base branch)
3. **Creates** a new branch in the target repository
4. **Commits** and **pushes** the changes
5. **Creates** a Pull Request via the GitHub REST API
6. **Outputs** the PR number and URL

## Design Documentation

See [docs/design.md](docs/design.md) for detailed research and design documentation, including:
- Authentication methods comparison
- API usage details
- Security considerations
- Architecture overview

## License

MIT