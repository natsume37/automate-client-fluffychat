# AutoMate Flutter Client - 构建指南

## 环境变量配置

本项目使用 Flutter 官方的 `--dart-define-from-file` 功能来管理环境变量，避免将敏感信息提交到版本控制。

### 必需的环境变量

1. **API_BASE_URL**: 客户端访问后端 API 的完整地址
2. **MATRIX_HOMESERVER**: Matrix homeserver 的完整地址
3. **K8S_NAMESPACE**: K3s Namespace（默认部署为 `automate`，用于 Push Gateway 集群域名）
4. **ALIYUN_SECRET_KEY**: 阿里云一键登录 SDK 密钥

### 可选环境变量

1. **APP_NAME**: 应用名称（用于本地数据库隔离）
2. **APP_ID_SUFFIX**: Android 包名后缀，例如 `.local`
3. **DICEBEAR_BASE_URL**: 自托管 DiceBear 地址（优先级最高）
4. 若未设置 `DICEBEAR_BASE_URL`，默认使用 `https://api.dicebear.com/9.x`

### 配置步骤

1. 复制环境变量模板：
```bash
cp env.json.example env.json
```

2. 编辑 `env.json` 文件，填入实际值：
```json
{
  "API_BASE_URL": "http://192.168.1.14:30081",
  "MATRIX_HOMESERVER": "http://192.168.1.14:30018",
  "K8S_NAMESPACE": "automate",
  "ALIYUN_SECRET_KEY": "your-actual-secret-key",
  "DICEBEAR_BASE_URL": "https://api.dicebear.com/9.x"
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

### 构建本地测试 APK（推荐）
```bash
flutter build apk --debug --target-platform android-arm64 --dart-define-from-file=env.json
```

### 构建 APK（Release）
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
- 若缺少 `android/key.properties` / `key.jks`，Android 构建会自动回退到 debug 签名，便于本地测试安装

## 检查 Flutter 版本

```bash
flutter --version
```

如果版本低于 3.7，请升级：
```bash
flutter upgrade
```
