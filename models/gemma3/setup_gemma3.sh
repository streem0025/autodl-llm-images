#!/bin/bash

# 设置颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# 打印带颜色的信息函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查是否为root用户
if [ "$EUID" -ne 0 ]; then
    print_error "请使用root权限运行此脚本"
    exit 1
fi

# 创建日志目录
mkdir -p /var/log
touch /var/log/ollama.log

print_info "开始安装Gemma3环境..."

# 1. 网络加速配置
print_info "配置网络加速..."
if [ -f "/etc/network_turbo" ]; then
    source /etc/network_turbo
    print_info "网络加速已配置"
else
    print_warning "未找到网络加速配置文件，将使用默认网络设置"
fi

# 2. 安装依赖
print_info "安装必要依赖..."
apt update
apt install -y lshw curl wget

# 3. 检查并安装Ollama
if command_exists ollama; then
    print_info "检测到Ollama已安装，跳过安装步骤"
else
    print_info "安装Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
fi

# 4. 创建Ollama配置目录
print_info "配置Ollama环境..."
mkdir -p /ollama/models

# 5. 创建Ollama配置文件
cat > /etc/ollama.env << EOF
# Ollama环境配置
OLLAMA_HOST=0.0.0.0:11434
OLLAMA_MODELS=/ollama/models
OLLAMA_KEEP_ALIVE=-1
OLLAMA_DEBUG=1
EOF

# 6. 创建启动和停止脚本
cat > /usr/local/bin/ollama-start << EOF
#!/bin/bash
source /etc/ollama.env
pid=\$(nohup ollama serve > /var/log/ollama.log 2>&1 & echo \$!)
echo \$pid > /var/tmp/ollama.pid
echo "Ollama服务已启动，PID: \$pid"
EOF

cat > /usr/local/bin/ollama-stop << EOF
#!/bin/bash
if [ -f /var/tmp/ollama.pid ]; then
    pid=\$(cat /var/tmp/ollama.pid)
    kill \$pid
    rm /var/tmp/ollama.pid
    echo "Ollama服务已停止，PID: \$pid"
else
    echo "未找到Ollama服务PID文件"
fi
EOF

chmod +x /usr/local/bin/ollama-start
chmod +x /usr/local/bin/ollama-stop

# 7. 添加到.bashrc
cat >> ~/.bashrc << EOF

# Ollama配置
source /etc/ollama.env
alias ollama-start='/usr/local/bin/ollama-start'
alias ollama-stop='/usr/local/bin/ollama-stop'
EOF

# 8. 启动Ollama服务
print_info "启动Ollama服务..."
source /etc/ollama.env
/usr/local/bin/ollama-start

# 等待服务启动
sleep 5

# 9. 下载Gemma3模型
print_info "开始下载Gemma3:12b模型..."
print_info "这可能需要一些时间，取决于您的网络速度..."
ollama pull gemma3:12b

print_info "安装完成！"
print_info "您可以使用以下命令运行Gemma3模型："
print_info "ollama run gemma3:12b --verbose"
print_info "使用 'ollama-stop' 停止服务，使用 'ollama-start' 启动服务" 