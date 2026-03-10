# AutoMate Flutter Client - 构建指南

## 环境变量配置

本项目使用 Flutter 官方的 `--dart-define-from-file` 功能来管理客户端构建配置。
CI 只会注入非敏感的后端地址和应用标识，不会把高敏感 secret 打进安装包。

### 必需的环境变量

1. **APP_NAME**: 应用名称
2. **APP_ID_SUFFIX**: Android 包名后缀（生产环境通常为空）
3. **K8S_NAMESPACE**: 后端所在命名空间
4. **API_BASE_URL**: Psygo Assistant 后端地址
5. **MATRIX_HOMESERVER**: Matrix Homeserver 地址
6. **CHATBOT_BASE_URL**: Onboarding chatbot 地址（可选）

### 配置步骤

1. 复制环境变量模板：
```bash
cp env.json.example env.json
```

2. 编辑 `env.json` 文件，填入实际值：
```json
{
  "APP_NAME": "Psygo",
  "APP_ID_SUFFIX": "",
  "K8S_NAMESPACE": "prod",
  "API_BASE_URL": "https://api.example.com/assistant",
  "MATRIX_HOMESERVER": "https://matrix.example.com",
  "CHATBOT_BASE_URL": "https://api.example.com/onboarding-chatbot"
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
- 请勿将敏感信息（如 `ALIYUN_SECRET_KEY`、`PUSH_*_APP_SECRET`）提交到代码仓库
- 客户端构建配置会被打进安装包，能被反编译提取，因此只应包含可公开的地址和标识
- 团队成员需要各自配置自己的 `env.json` 文件
- 确保使用 Flutter 3.7 或更高版本以支持 `--dart-define-from-file`

### 本地调试的可选 secret

如果你在本地调试移动端一键登录或阿里云推送，可以手动在未提交的 `env.json`
里额外加入 `ALIYUN_SECRET_KEY` 或 `PUSH_*` 键，但不要放进 GitHub Variables /
Secrets 再注入客户端正式包。

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
当前上传平台为：Android、Linux、Windows、Web。
版本号按工作流运行号自动递增，每次增加 `0.01`，用于避免同 key 覆盖。

### 触发方式

在 GitHub Actions 中手动运行 `Cross Platform CI`，可配置：

1. `upload_to_cos`：是否上传构建产物到 COS（布尔值）
2. `target_channel`：是否更新渠道指针（`none/dev/test/release`）
3. `app_name`：对象 key 前缀中的应用名（默认 `fluffychat`）

Linux 产物会同时包含：

1. `fluffychat-linux-x64.tar.gz`
2. `psygo-linux-amd64.deb`

### COS 必需 Secrets

在仓库 Secrets 中配置：

1. `COS_SECRET_ID`
2. `COS_SECRET_KEY`
3. `COS_BUCKET`
4. `COS_REGION`

### 客户端构建所需 GitHub Variables

为了让 CI 产物指向真实后端，在仓库 Variables 或 `prod` Environment Variables 中配置：

1. `APP_NAME`
2. `APP_ID_SUFFIX`
3. `K8S_NAMESPACE`
4. `API_BASE_URL`
5. `MATRIX_HOMESERVER`
6. `CHATBOT_BASE_URL`（可选）

### 存储结构

上传后结构如下（`{build_version}` 每次发布 +0.01，`{git_sha}` 为本次构建提交，`{channel}` 为 `dev/test/release`）：

```text
artifacts/{app_name}/{build_version}/{git_sha}/{platform}/{file}
{channel}/{app_name}/linux/fluffychat-linux-x64.tar.gz
{channel}/{app_name}/linux/psygo-linux-amd64.deb
{channel}/{app_name}/windows64/fluffychat-windows-x64.zip
{channel}/{app_name}/android-apk/fluffychat-android-apk.apk
{channel}/{app_name}/manifest.json
manifests/{build_version}.json
channels/dev.json
channels/test.json
channels/release.json
```

说明：

1. `artifacts` 为不可变产物目录
2. `{channel}/{app_name}/...` 为渠道直链目录，适合直接给测试环境拉取最新 Linux、Windows64、Android APK
3. `manifests/{build_version}.json` 记录每个文件的校验和、大小、平台、不可变对象 key，以及渠道目录对象 key
4. `channels/*.json` 保存当前渠道指向的版本信息和渠道目录前缀，可用于快速回滚
