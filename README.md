# autodl-llm-images

在AutoDL平台可使用的一些LLM镜像及使用说明。本仓库提供了多种预配置的大语言模型镜像，方便在AutoDL平台上快速部署和使用。

## 项目简介

本项目旨在为AutoDL平台用户提供开箱即用的大语言模型镜像，包括但不限于：
- 预装常用LLM模型
- 提供简单易用的启动脚本
- 支持本地和远程服务模式
- 详细的使用文档和示例

## 可用模型

目前支持以下模型：

| 模型名称 | 描述 | 文档链接 |
|---------|------|---------|
| Gemma 3 | 基于ollama提供的gemma3:12b模型服务 | [使用说明](models/gemma3/README.md) |

## 使用方法

每个模型都有其独立的使用说明文档，请点击上表中的文档链接查看详细使用方法。

## 未来计划

我们计划添加更多流行的大语言模型支持，如：
- Claude
- Llama 3
- Mistral
- 更多中文大模型

## 贡献指南

欢迎贡献新的模型镜像或改进现有镜像。请遵循以下步骤：
1. Fork本仓库
2. 创建您的特性分支 (`git checkout -b feature/amazing-model`)
3. 提交您的更改 (`git commit -m 'Add some amazing model'`)
4. 推送到分支 (`git push origin feature/amazing-model`)
5. 创建新的Pull Request

## 许可证

本项目采用MIT许可证 - 详见 [LICENSE](LICENSE) 文件

# Gemma3 模型部署指南

本项目提供了一键部署 Google Gemma3 大语言模型的脚本和使用说明。通过 Ollama 平台，您可以在本地环境中轻松运行 Gemma3 模型。

## 环境要求

- Linux 操作系统（推荐 Ubuntu 或 Debian）
- Root 权限
- NVIDIA GPU（推荐，但不是必须）
- 至少 16GB 内存
- 至少 30GB 可用磁盘空间

## 快速开始

### 一键安装

1. 克隆本仓库：
   ```bash
   git clone https://github.com/yourusername/autodl-llm-images.git
   cd autodl-llm-images
   ```

2. 运行安装脚本：
   ```bash
   sudo bash models/gemma3/setup_gemma3.sh
   ```

3. 安装过程将自动完成以下步骤：
   - 配置网络加速（如果可用）
   - 安装必要依赖
   - 安装 Ollama（如果尚未安装）
   - 配置 Ollama 环境
   - 创建服务管理脚本
   - 启动 Ollama 服务
   - 下载 Gemma3:12b 模型

### 使用模型

安装完成后，您可以使用以下命令运行 Gemma3 模型：

```bash
ollama run gemma3:12b --verbose
```

## 服务管理

脚本安装了便捷的服务管理命令：

- 启动服务：`ollama-start`
- 停止服务：`ollama-stop`
- 查看日志：`cat /var/log/ollama.log`

## 环境配置

Ollama 环境配置存储在 `/etc/ollama.env` 文件中，包含以下设置：

```
OLLAMA_HOST=0.0.0.0:11434  # 服务监听地址和端口
OLLAMA_MODELS=/ollama/models  # 模型存储路径
OLLAMA_KEEP_ALIVE=-1  # 模型保持加载状态，不自动释放
OLLAMA_DEBUG=1  # 启用调试日志
```

## 常见问题

### 1. 安装过程中出现网络问题

如果安装过程中遇到网络问题，可以尝试使用网络加速：
- 确认 `/etc/network_turbo` 文件是否存在
- 如果不存在，可以考虑使用代理或镜像源

### 2. GPU 未被正确识别

确保已安装 NVIDIA 驱动和 CUDA。可以运行以下命令检查：
```bash
nvidia-smi
```

### 3. 服务无法启动

检查日志文件获取详细错误信息：
```bash
cat /var/log/ollama.log
```

## 高级用法

### 自定义模型参数

运行模型时可以设置自定义参数：

```bash
ollama run gemma3:12b --verbose --system "你是一个有用的AI助手"
```

### API 调用

Ollama 提供了 REST API，可以通过以下方式调用：

```bash
curl -X POST http://localhost:11434/api/generate -d '{
  "model": "gemma3:12b",
  "prompt": "你好，请介绍一下自己",
  "stream": false
}'
```

## 许可证

本项目遵循 [MIT 许可证](LICENSE)。请注意，Gemma3 模型本身有其自己的使用条款，详情请参阅 [Google Gemma 许可证](https://ai.google.dev/gemma/terms)。
