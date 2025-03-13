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
