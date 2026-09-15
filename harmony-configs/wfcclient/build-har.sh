#!/usr/bin/env bash
#
# 把本目录的源码打包成 wfcclient.har，输出到
# harmony-configs/libs/wfcclient.har
#
# 为什么要打成 har 而不是直接当源码模块用：
# 鸿蒙工程开了 useNormalizedOHMUrl 之后，**源码模块**必须被引用方在自己的
# oh-package.json5 里显式声明才能解析；而 uts 插件生成的 oh-package.json5 只能通过
# utssdk/app-harmony/config.json 配置，且 config.json 里的相对路径会被限制在插件目录内，
# 指不到 harmony-configs 下的源码模块。**har 依赖**则没有这个限制
# （avenginekit.har / ptt.har 内部 `import '@wfc/client/...'` 也能解析到）。
#
# 为什么输出到 harmony-configs/libs：wfc-av-client 和 wfc-ptt-client 都要用它，
# 在工程根 harmony-configs/oh-package.json5 里声明一份，详见 README.md。
#
# 用法：./build-har.sh
# 依赖：DevEco-Studio（提供 node / hvigor / ohpm / SDK）

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
OUT_DIR="$PROJECT_ROOT/harmony-configs/libs"

DEVECO="/Applications/DevEco-Studio.app/Contents"
export DEVECO_SDK_HOME="$DEVECO/sdk"
NODE="$DEVECO/tools/node/bin/node"
HVIGOR="$DEVECO/tools/hvigor/bin/hvigorw.js"
OHPM="$DEVECO/tools/ohpm/bin/ohpm"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/libs"
cp "$PROJECT_ROOT/harmony-configs/libs/marswrapper.har" "$WORK/libs/"
cp -R "$SRC_DIR" "$WORK/wfcclient"
rm -rf "$WORK/wfcclient/build" "$WORK/wfcclient/oh_modules"

cat > "$WORK/hvigorfile.ts" <<'EOF'
import { appTasks } from '@ohos/hvigor-ohos-plugin';
export default { system: appTasks, plugins: [] }
EOF

mkdir -p "$WORK/hvigor"
cat > "$WORK/hvigor/hvigor-config.json5" <<'EOF'
{
  "modelVersion": "5.0.0",
  "dependencies": {},
  "execution": {},
  "logging": {},
  "debugging": {},
  "nodeOptions": {}
}
EOF

mkdir -p "$WORK/AppScope"
cat > "$WORK/AppScope/app.json5" <<'EOF'
{
  "app": {
    "bundleName": "cn.wildfirechat.wfcclient.build",
    "vendor": "wildfirechat",
    "versionCode": 1,
    "versionName": "1.0.0",
    "icon": "$media:app_icon",
    "label": "$string:app_name"
  }
}
EOF

cat > "$WORK/oh-package.json5" <<'EOF'
{
  "modelVersion": "5.0.0",
  "name": "wfcclient-build",
  "version": "1.0.0",
  "description": "build host for wfcclient.har",
  "main": "",
  "author": "",
  "license": "",
  "dependencies": {
    "@wfc/marswrapper": "file:./libs/marswrapper.har"
  }
}
EOF

cat > "$WORK/build-profile.json5" <<'EOF'
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "5.0.0(12)",
        "runtimeOS": "HarmonyOS",
        "compatibleSdkVersionStage": "beta6",
        "buildOption": {
          "strictMode": { "caseSensitiveCheck": true, "useNormalizedOHMUrl": true }
        }
      }
    ],
    "buildModeSet": [{ "name": "debug" }, { "name": "release" }]
  },
  "modules": [
    { "name": "wfcclient", "srcPath": "./wfcclient" }
  ]
}
EOF

cd "$WORK"
"$OHPM" install --all
"$NODE" "$HVIGOR" --mode module -p module=wfcclient@default -p product=default \
    -p buildMode=release assembleHar --no-daemon

mkdir -p "$OUT_DIR"
cp "$WORK/wfcclient/build/default/outputs/default/wfcclient.har" "$OUT_DIR/wfcclient.har"
echo "输出：$OUT_DIR/wfcclient.har"
