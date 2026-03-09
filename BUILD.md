# AutoMate Flutter Client - 构建指南

## 环境变量配置

本项目使用 Flutter 官方的 `--dart-define-from-file` 功能来管理环境变量，避免将敏感信息提交到版本控制。

### 必需的环境变量

1. **K8S_NODE_IP**: K8s 集群节点 IP（局域网访问）
2. **ALIYUN_SECRET_KEY**: 阿里云一键登录 SDK 密钥

### 配置步骤

1. 复制环境变量模板：
```bash
cp env.json.example env.json
```

2. 编辑 `env.json` 文件，填入实际值：
```json
{
  "K8S_NODE_IP": "192.168.31.22",
  "ALIYUN_SECRET_KEY": "your-actual-secret-key"
}
```

## 构建命令

### 最简单的方式（推荐）

```bash
flutter run --dart-define-from-file=env.json
```

### 开发构建（Debug）
```bash
flutter run --dart-define-from-file=env.json -d V2403A
```

### 生产构建（Release）
```bash
flutter run --release --dart-define-from-file=env.json -d V2403A
```

### 构建 APK
```bash
flutter build apk --release --dart-define-from-file=env.json
```

### 使用脚本简化构建

项目提供了 `build.sh` 脚本（已废弃，推荐直接使用 Flutter 命令）：

```bash
./build.sh
```

## 注意事项

- `env.json` 文件已添加到 `.gitignore`，不会被提交到版本控制
- 请勿将敏感信息（如 Secret Key）提交到代码仓库
- 团队成员需要各自配置自己的 `env.json` 文件
- 确保使用 Flutter 3.7 或更高版本以支持 `--dart-define-from-file`

## 检查 Flutter 版本

```bash
flutter --version
```

如果版本低于 3.7，请升级：
```bash
flutter upgrade
```

## CI 对象存储发布（腾讯 COS）

`Cross Platform CI` 支持手动触发后将产物上传到腾讯 COS，并可选更新 `dev/test/release` 渠道指针。
当前上传平台为：Android、Linux、Windows。
版本号按工作流运行号自动递增，每次增加 `0.01`，用于避免同 key 覆盖。

### 触发方式

在 GitHub Actions 中手动运行 `Cross Platform CI`，可配置：

1. `upload_to_cos`：是否上传构建产物到 COS（布尔值）
2. `target_channel`：是否更新渠道指针（`none/dev/test/release`）
3. `app_name`：对象 key 前缀中的应用名（默认 `fluffychat`）

### COS 必需 Secrets

在仓库 Secrets 中配置：

1. `COS_SECRET_ID`
2. `COS_SECRET_KEY`
3. `COS_BUCKET`
4. `COS_REGION`

### 存储结构

上传后结构如下（`{build_version}` 每次发布 +0.01，`{git_sha}` 为本次构建提交）：

```text
artifacts/{app_name}/{build_version}/{git_sha}/{platform}/{file}
manifests/{build_version}.json
channels/dev.json
channels/test.json
channels/release.json
```

说明：

1. `artifacts` 为不可变产物目录
2. `manifests/{build_version}.json` 记录每个文件的校验和、大小、平台和对象 key
3. `channels/*.json` 只保存当前渠道指向的版本信息，可用于快速回滚
