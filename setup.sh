#!/bin/bash

# ==============================================================================
# JJPlayer - 项目一键初始化脚本 (setup.sh)
# ==============================================================================
# 适合团队协作中，新开发者克隆项目后一键安装 SwiftLint 和 SwiftFormat 依赖。
# ==============================================================================

# 确保脚本遇到错误时立即退出
set -e

# 终端文字颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # 清除颜色

echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}                 欢迎使用 JJPlayer 项目开发环境一键初始化脚本                ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo ""

# 1. 验证操作系统是否为 macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo -e "${RED}[Error] 本项目为 iOS/Swift 工程，本初始化脚本仅支持 macOS 系统。${NC}"
    exit 1
fi

# 2. 检查并安装 Homebrew
echo -e "${YELLOW}[1/3] 正在检查 macOS 软件包管理器 Homebrew 环境...${NC}"
if ! which brew >/dev/null; then
    echo -e "${RED}[提示] 系统未检测到 Homebrew。${NC}"
    echo -e "${YELLOW}请先复制并运行以下官方命令手动安装 Homebrew，随后重新运行本脚本：${NC}"
    echo -e "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
else
    echo -e "${GREEN}[✔] Homebrew 已就绪: $(brew -v | head -n 1)${NC}"
fi
echo ""

# 3. 检查并安装 SwiftLint (静态规则扫描)
echo -e "${YELLOW}[2/3] 正在检查 SwiftLint 静态代码扫描工具...${NC}"
if ! which swiftlint >/dev/null; then
    echo -e "${YELLOW}[提示] 未检测到 SwiftLint，正在通过 Homebrew 为您安装，请稍候...${NC}"
    brew install swiftlint
    echo -e "${GREEN}[✔] SwiftLint 安装成功！${NC}"
else
    echo -e "${GREEN}[✔] SwiftLint 已就绪: 版本 $(swiftlint --version)${NC}"
fi
echo ""

# 4. 检查并安装 SwiftFormat (代码自动格式化)
echo -e "${YELLOW}[3/3] 正在检查 SwiftFormat 代码自动重排工具...${NC}"
if ! which swiftformat >/dev/null; then
    echo -e "${YELLOW}[提示] 未检测到 SwiftFormat，正在通过 Homebrew 为您安装，请稍候...${NC}"
    brew install swiftformat
    echo -e "${GREEN}[✔] SwiftFormat 安装成功！${NC}"
else
    echo -e "${GREEN}[✔] SwiftFormat 已就绪: 版本 $(swiftformat --version)${NC}"
fi
echo ""

# 5. 完成安装，进行首次联调测试
echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}                       🎉 所有开发依赖项已全部就绪！                    ${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo ""

echo -e "${YELLOW}[提示] 正在执行首次代码格式化与规范扫描验证...${NC}"

# 显式引入 Homebrew 的 Path（防止脚本上下文里找不到命令）
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# 首次运行 SwiftFormat 格式化
if which swiftformat >/dev/null; then
    echo -e "${GREEN}👉 正在自动格式化代码...${NC}"
    swiftformat .
fi

# 首次运行 SwiftLint 扫描
if which swiftlint >/dev/null; then
    echo -e "${GREEN}👉 正在执行静态规范扫描...${NC}"
    swiftlint --config .swiftlint.yml
fi

echo ""
echo -e "${GREEN}🚀 初始化完全成功！您现在可以双击打开 JJPlayer.xcodeproj 愉快地开发了。${NC}"
