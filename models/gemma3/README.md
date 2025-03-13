> 你是否如我一样本机并不能流畅体验最新的Gemma3模型？那么将云GPU搬到本地来使用吧～～

## 简要说明
基于ollama提供了开箱即用的gemma3:12b模型服务。
提供脚本帮助一键将云服务切换到本地模式使用。

## 使用方式
### server模式
只需要一句话启动`ollama`服务即可，如果目标是将远程服务以本地模型使用，执行这个。

```bash
ollama-start
```

注意启动的服务监听在本地的`11434`端口。

### 会话模式
可以使用ollama的命令如`ollama list`查看模型。使用run来直接跑起来体验一下。
```bash
ollama run gemma3:12b --verbose
```
在4090 24G显卡上，能有70 token/s，速度很快。

## 将远程服务映射到本地
按如下图找到ssh转发的命令，把其中的端口两个6006都修改为我们ollama监听端口`11434`。
![SSH转发设置](https://github.com/kevin1sMe/autodl-llm-images/raw/main/docs/images/ssh_port_forwarding.png)

```bash
ssh -CNg -L 11434:127.0.0.1:11434 root@connect.nmb1.seetacloud.com -p 21951
```

## 在本地使用ollama模型
![本地使用ollama](https://github.com/kevin1sMe/autodl-llm-images/raw/main/docs/images/local_ollama_usage.png)

这样就如本地一样开心的使用ollama模型吧～～

## 补充：基础镜像
![基础镜像选择](https://github.com/kevin1sMe/autodl-llm-images/raw/main/docs/images/base_image_selection.png)
本镜像基于`PyTorch  2.5.1` + `Python  3.12(ubuntu22.04)` + `Cuda  12.4`。

