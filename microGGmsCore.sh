#!/bin/bash
# 1. Android SDK 安装路径
#    脚本会自动将 SDK 下载并安装到这里。
ANDROID_SDK_ROOT="$HOME/Android/Sdk"

# 2. 最终 APK 输出目录
#    编译成功后，最终的 APK 文件会放在这里。
OUTPUT_DIR="$HOME/microg_build_output"

# 3. 签名密钥配置
#    用于给编译好的 APK 签名。脚本会自动创建。
#    !!! 警告: 请妥善保管好生成的密钥文件，卸载重装时需要用同一个密钥签名。
KEYSTORE_NAME="microg_release.jks"
KEYSTORE_ALIAS="microg"
KEYSTORE_PASS="change-this-password" # 强烈建议修改此默认密码

# --- 脚本主体 (无需修改) ---

set -e # 任何命令失败则立即退出脚本

# 函数: 打印带颜色的信息
function print_info() {
    echo -e "\n\e[34m[INFO] $1\e[0m"
}

# 1. 检查并安装依赖
print_info "步骤 1/6: 检查并安装系统依赖..."
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk git wget unzip

# 设置 Java 17 为当前环境使用
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-amd64"
export PATH="$JAVA_HOME/bin:$PATH"
print_info "Java 环境已设置为 Java 17。"

# 2. 配置 Android SDK
print_info "步骤 2/6: 配置 Android SDK..."
if [ ! -d "$ANDROID_SDK_ROOT" ]; then
    print_info "Android SDK 未找到，正在自动下载并安装..."
    # 从官方源下载最新的命令行工具
    CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
    CMDLINE_TOOLS_ZIP=$(basename "$CMDLINE_TOOLS_URL")
    
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    wget -q --show-progress "$CMDLINE_TOOLS_URL" -O "/tmp/$CMDLINE_TOOLS_ZIP"
    unzip -q /tmp/$CMDLINE_TOOLS_ZIP -d "$ANDROID_SDK_ROOT/cmdline-tools"
    # SDK 管理器期望的目录结构是 cmdline-tools/latest
    mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    rm "/tmp/$CMDLINE_TOOLS_ZIP"
    print_info "SDK 命令行工具下载完成。"
else
    print_info "Android SDK 已存在于 $ANDROID_SDK_ROOT。"
fi

# 设置 SDK 环境变量
export ANDROID_SDK_HOME="$ANDROID_SDK_ROOT"
export ANDROID_HOME="$ANDROID_SDK_ROOT" # 兼容旧版配置
export PATH="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"

# 使用 sdkmanager 安装必要的平台和构建工具
print_info "正在安装 SDK platform 和 build-tools..."
# 自动接受所有 SDK 许可协议
yes | sdkmanager --licenses > /dev/null
sdkmanager "platforms;android-29" "build-tools;34.0.0" > /dev/null
print_info "SDK 配置完成。"

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
# 定位到 'play-services-core/build.gradle' 文件
TARGET_GRADLE_FILE="play-services-core/build.gradle"
# 在 defaultConfig 块的 'versionName' 配置后插入 ndk.abiFilters
sed -i "/versionName project.version/a \            ndk {\n                abiFilters 'arm64-v8a'\n            }" "$TARGET_GRADLE_FILE"
print_info "源码修改成功！"

# 4. 执行 Gradle 编译
print_info "步骤 4/6: 开始执行 Gradle 编译 (这可能需要几分钟)..."
# 创建 local.properties 指向 SDK 路径
echo "sdk.dir=$ANDROID_SDK_ROOT" > local.properties
# 增加 Gradle 运行内存，防止编译过程中内存溢出
echo "org.gradle.jvmargs=-Xmx4g" >> gradle.properties

# 赋予 gradlew 执行权限并开始构建
chmod +x ./gradlew
./gradlew build

print_info "编译成功！未签名的 APK 已生成。"

# 5. 签名并优化 APK
print_info "步骤 5/6: 签名并优化 APK..."
# 创建输出目录和密钥库目录
mkdir -p "$OUTPUT_DIR"
KEYSTORE_FILE="$OUTPUT_DIR/$KEYSTORE_NAME"

# 如果密钥库不存在，则自动创建一个
if [ ! -f "$KEYSTORE_FILE" ]; then
    print_info "签名密钥 $KEYSTORE_NAME 不存在，正在自动创建..."
    keytool -genkey -v -keystore "$KEYSTORE_FILE" -alias "$KEYSTORE_ALIAS" \
            -keyalg RSA -keysize 2048 -validity 10000 \
            -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
            -dname "CN=microG, OU=microG, O=microG, L=Unknown, ST=Unknown, C=XX"
    print_info "密钥已创建并保存于 $KEYSTORE_FILE。请务必妥善备份此文件！"
fi

# 定义文件路径
UNSIGNED_APK="play-services-core/build/outputs/apk/release/play-services-core-release-unsigned.apk"
FINAL_APK="$OUTPUT_DIR/GmsCore_arm64-v8a_$(date +%Y%m%d).apk"

# 使用 jarsigner 进行签名
print_info "正在使用 jarsigner 签名..."
jarsigner -verbose -sigalg SHA1withRSA -digestalg SHA1 \
          -keystore "$KEYSTORE_FILE" -storepass "$KEYSTORE_PASS" \
          -signedjar "$OUTPUT_DIR/signed_temp.apk" \
          "$UNSIGNED_APK" "$KEYSTORE_ALIAS"

# 使用 zipalign 进行优化对齐
print_info "正在使用 zipalign 优化..."
"$ANDROID_SDK_ROOT/build-tools/34.0.0/zipalign" -v 4 \
                                                  "$OUTPUT_DIR/signed_temp.apk" \
                                                  "$FINAL_APK"

# 清理临时文件
rm "$OUTPUT_DIR/signed_temp.apk"

# 6. 完成
print_info "步骤 6/6: 全部完成！"
echo -e "\e[32m======================================================================\e[0m"
echo -e "\e[32m编译成功！\e[0m"
echo -e "\e[32m最终的 ARM64-v8a 版本 APK 已保存到:\e[0m"
echo -e "\e[1;33m$FINAL_APK\e[0m"
echo -e "\e[32m======================================================================\e[0m"

exit 0
