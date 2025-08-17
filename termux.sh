#!/bin/bash
# 1. Termux Android SDK 路径 (由 'android-sdk-tools' 包提供)
#    这个路径是固定的，请勿修改。
TERMUX_SDK_ROOT="/data/data/com.termux/files/usr/share/android-sdk"

# 2. 最终 APK 输出目录
#    编译成功后，APK 文件会放在手机的 'Download' 文件夹中。
OUTPUT_DIR="~/data/data/com.termux/files"

# 3. 签名密钥配置
KEYSTORE_DIR="~/.keystore"
KEYSTORE_NAME="microg_termux_release.jks"
KEYSTORE_ALIAS="microg"
KEYSTORE_PASS="change-this-password" # 强烈建议修改此默认密码

# --- 脚本主体 ---

set -e # 任何命令失败则立即退出脚本

# 函数: 打印带颜色的信息
function print_info() {
    echo -e "\n\e[34m[INFO] $1\e[0m"
}

# 1. 更新包列表并安装依赖
print_info "步骤 1/6: 安装/更新 Termux 依赖包..."
pkg update -y
pkg install -y openjdk-17 git wget unzip apksigner aapt

# 2. 验证 Termux "SDK" 环境
print_info "步骤 2/6: 验证 Termux Android SDK 环境..."
if [ ! -d "$TERMUX_SDK_ROOT" ]; then
    echo -e "\e[31m[错误] Termux 的 Android SDK 路径未找到! 请尝试运行 'pkg install android-sdk-tools'。\e[0m"
    exit 1
fi
print_info "Termux SDK 环境正常。"

# 3. 克隆并修改 microG GmsCore 源码
print_info "步骤 3/6: 克隆并修改 GmsCore 源码..."
# 如果旧目录存在，则删除以确保全新克隆
if [ -d "GmsCore" ]; then
    print_info "发现旧的 GmsCore 目录，正在删除以进行全新克隆..."
    rm -rf GmsCore
fi
git clone https://github.com/microg/GmsCore.git
cd GmsCore

print_info "正在修改 build.gradle 以仅编译 ARM64-v8a 架构..."
TARGET_GRADLE_FILE="play-services-core/build.gradle"
# 在 defaultConfig 块的 'versionName' 配置后插入 ndk.abiFilters
sed -i "/versionName project.version/a \            ndk {\n                abiFilters 'arm64-v8a'\n            }" "$TARGET_GRADLE_FILE"
print_info "源码修改成功！"

# 4. 执行 Gradle 编译
print_info "步骤 4/6: 开始执行 Gradle 编译 (这将非常耗时，请保持耐心)..."
# 创建 local.properties 指向 Termux 的 SDK 路径
echo "sdk.dir=$TERMUX_SDK_ROOT" > local.properties
# 增加 Gradle 运行内存，对于手机尤其重要
echo "org.gradle.jvmargs=-Xmx2g" >> gradle.properties

# 赋予 gradlew 执行权限并开始构建
chmod +x ./gradlew
./gradlew build

print_info "编译成功！未签名的 APK 已生成。"

# 5. 签名并优化 APK
print_info "步骤 5/6: 签名并优化 APK..."
# 创建输出目录和密钥库目录
eval mkdir -p "$OUTPUT_DIR"
eval mkdir -p "$KEYSTORE_DIR"
KEYSTORE_FILE=$(eval echo "$KEYSTORE_DIR/$KEYSTORE_NAME")

# 如果密钥库不存在，则自动创建一个
if [ ! -f "$KEYSTORE_FILE" ]; then
    print_info "签名密钥 $KEYSTORE_NAME 不存在，正在自动创建..."
    keytool -genkey -v -keystore "$KEYSTORE_FILE" -alias "$KEYSTORE_ALIAS" \
            -keyalg RSA -keysize 2048 -validity 10000 \
            -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
            -dname "CN=microG, OU=Termux, O=microG, L=Unknown, ST=Unknown, C=XX"
    print_info "密钥已创建并保存于 $KEYSTORE_FILE。请务必妥善备份此文件！"
fi

# 定义文件路径
UNSIGNED_APK="play-services-core/build/outputs/apk/release/play-services-core-release-unsigned.apk"
FINAL_APK=$(eval echo "$OUTPUT_DIR/GmsCore_arm64-v8a_$(date +%Y%m%d).apk")

# 使用 jarsigner 进行签名
print_info "正在使用 jarsigner 签名..."
jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 \
          -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" \
          -signedjar "signed_temp.apk" \
          "$UNSIGNED_APK" "$KEYSTORE_ALIAS"

# 使用 zipalign 进行优化对齐 (由 apksigner 包提供)
print_info "正在使用 zipalign 优化..."
zipalign -v 4 "signed_temp.apk" "$FINAL_APK"

# 清理临时文件
rm "signed_temp.apk"

# 6. 完成
print_info "步骤 6/6: 全部完成！"
echo -e "\e[32m======================================================================\e[0m"
echo -e "\e[32m编译成功！\e[0m"
echo -e "\e[32m最终的 ARM64-v8a 版本 APK 已保存到你的手机下载目录:\e[0m"
echo -e "\e[1;33m$FINAL_APK\e[0m"
echo -e "\e[32m======================================================================\e[0m"

exit 0
