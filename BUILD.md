# AutoMate Flutter Client - 构建指南

## 环境变量配置

本项目使用 Flutter 官方的 `--dart-define-from-file` 功能来管理环境变量，避免将敏感信息提交到版本控制。

### 必需的环境变量

1. **K8S_NODE_IP**: K8s 集群节点 IP（局域网访问）
2. **ALIYUN_SECRET_KEY**: 阿里云一键登录 SDK 密钥

### 可选环境变量

1. **DICEBEAR_BASE_URL**: 自托管 DiceBear 地址（优先级最高）
2. 若未设置 `DICEBEAR_BASE_URL`，默认使用 `https://api.dicebear.com/9.x`

### 配置步骤

1. 复制环境变量模板：
```bash
cp env.json.example env.json
```

2. 编辑 `env.json` 文件，填入实际值：
```json
{
  "K8S_NODE_IP": "192.168.31.22",
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
