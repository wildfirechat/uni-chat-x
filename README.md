## 最重要的事，说三遍!!!
> 以下说明，仅针对 Android 端，iOS 端可以直接配置`IM_SERVER_HOST`，鸿蒙 SDK 是付费的，需要[申请试用](https://wildfirechat.cn/trial/)

**因反诈合规要求，本项目协议栈默认仅支持连接野火官方服务，不能连接到自行部署的服务。如需获取不受限版本，请联系官方微信（wfchat 或 wildfirechat）免费申请。**

**严禁将本项目用于非法诈骗。**

**因反诈合规要求，本项目协议栈默认仅支持连接野火官方服务，不能连接到自行部署的服务。如需获取不受限版本，请联系官方微信（wfchat 或 wildfirechat）免费申请。**

**严禁将本项目用于非法诈骗。**

**因反诈合规要求，本项目协议栈默认仅支持连接野火官方服务，不能连接到自行部署的服务。如需获取不受限版本，请联系官方微信（wfchat 或 wildfirechat）免费申请。**

**严禁将本项目用于非法用途。**

**给您带来不便，敬请谅解。**

> 联系官方获取到不受限制版本后，请替换`./uni_modules/wfc-client/utssdk/app-android/libs/mars-core-release.aar`文件，并重新制作基座

---------

# 野火uni-app x uts demo

支持 Android、iOS 和 HarmonyOS 端

> 这是适配 uni-app x 的版本，原来的uts 版本，请参考 `uni-app-uts`分支

## HarmonyOS 特别说明

1. Android、iOS 端，是免费的
2. 野火IM 鸿蒙 SDK 是需要付费的，鸿蒙 5.0 上，默认只能连到官方服务，需要申请试用才能连到自行部署的`im-server`
3. 申请试用，具体请看 [试用](https://docs.wildfirechat.cn/trial/)

## Android 端特别说明
1. 由于 HBuilderX 的原因，制作自定义调试基座和云打包时，配置和本地运行无法统一，需要根据当前情况进行切换，具体请参考`uni_modules/wfc-av-client/utssdk/app-android/README.md`

## 更新鸿蒙 SDK（marswrapper.har）

鸿蒙端原生 SDK 通过`harmony-configs/oh-package.json5`中的本地文件依赖引入：`"@wfc/marswrapper": "file:./libs/marswrapper.har"`。

**重要提醒：只替换 har 文件不会生效。** 该依赖是`file:`本地依赖，且 har 内版本号固定为`1.0.0`，ohpm 安装时会把它解到`oh_modules/.ohpm`缓存中，仅替换文件不会触发重新安装，编译出来的应用仍是旧库。

更新步骤：

1. 用新版`marswrapper.har`覆盖`harmony-configs/libs/marswrapper.har`
2. HBuilderX 重新生成/同步鸿蒙工程后，到**生成的鸿蒙工程目录**下删除 ohpm 缓存并重装依赖：
    ```bash
    rm -rf oh_modules/.ohpm entry/oh_modules
    ohpm install
    ```
    使用 DevEco Studio 时对应操作：删除上述目录后，执行 File -> Sync and Refresh Project
3. 验证更新是否生效，确认生成的鸿蒙工程下`oh_modules/@wfc/marswrapper/libs/arm64-v8a/`里的`.so`文件日期/大小已变为新版

## 配置

1. 购买[野火IM uts插件](https://ext.dcloud.net.cn/plugin?id=20059) 已包含在项目，一般不用特殊处理
2. manifest.json 基础配置里面，选择蒸汽模式，非蒸汽模式时，长按菜单有点问题
3. 如果使用野火官方服务，直接编译运行即可。如果使用自己私有部署IM服务，需要在[config.uts](./config.uts)配置应用服务地址和IM服务地址。修改如下配置：
    ```
    // 下面两个配置都要一起修复，否则登录进去之后，会马上退回登录界面
    //应用服务地址
    static APP_SERVER = 'http//wildfirechat.net:8888';

    //IM 服务Host，不能包含 http 前缀或者端口，不支持设置端口，端口是写死的 80
    static IM_SERVER_HOST = 'wildfirechat.net';
    ```

## 运行

1. HBuilderX 制作自定义基座，可参考[什么是自定义调试基座及使用说明](https://ask.dcloud.net.cn/article/35115)
2. HBuilderX，运行基座选择：自定义调试基座
3. HBuilderX，运行到 Android App 基座、iOS App 基座 或 鸿蒙

> 如果没有制作并运行到自定义基座，那么野火原生插件就没有集成进去，将无法使用野火原生插件，界面会显示白屏。所以一定要严格按照上述步骤执行。

## 部署服务端

本应用默认连接野火官方服务。私有化部署服务，请按照 [服务器快速部署](https://docs.wildfirechat.cn/quick_start/server.html) 来部署服务到您自己的服务器。

## 野火IM插件使用说明

有2种插件的使用方法，一种是基于野火提供的Demo直接进行二次开发；另外一种是把野火插件放到现有项目中。

### 集成到现有项目

1. 下载[野火IM uts插件](https://ext.dcloud.net.cn/plugin?id=20059)，并导入到项目中。
2. 把野火UniApp平台的demo中的[wfc](https://gitee.com/wfchat/uni-chat-x/tree/main/wfc)目录和配置文件[config.uts](https://gitee.com/wfchat/uni-chat-x/blob/main/config.uts)拷贝到现有工程中。
3. 配置```config.uts```中的IM服务和应用服务地址。
4. 调用接口类[wfc.uts](https://gitee.com/wfchat/uni-chat-x/blob/main/wfc/client/wfc.uts)来使用野火插件。

## 源码地址

1. Android 和 iOS uts 插件源码在[uni-wfc-client 项目 uts 分支](https://gitee.com/wfchat/uni-wfc-client)
2. 本 demo 源码在[demo源码工程](https://gitee.com/wfchat/uni-chat-x)

## 技术支持

如果遇到问题，可以去[插件源码工程](https://gitee.com/wfchat/uni-wfc-client)或者[demo源码工程](https://gitee.com/wfchat/uni-chat-x)提issue，也可以去[野火论坛](https://bbs.wildfirechat.cn)发帖子问题，我们会尽快回复。谢谢大家的支持。

## 抓取原生插件的日志

1. ```Android```端，可以通过```adb logcat > wfc.log```进行抓去日志，如果提示找不到```adb```命令，请参考 [这儿](https://uniapp.dcloud.net.cn/tutorial/run/run-app-faq.html)
2. ```iOS```端，请连接```Xcode```抓取
3. `HarmonyOs`，请使用`hdc`或`DevEco Studio`抓取

## 推送
> 由于需要支持鸿蒙，故只能使用 uniPush 2.0
1. `HBuilder X`里面选中`manifest.json`，然后`安卓/iOS模板配置` -> `Push`-> `uniPush 2.0` -> 离线推送（并选中需要支持的手机品牌）
2. 参考[uni-push v2](https://uniapp.dcloud.net.cn/unipush-v2.html)，并进行相关配置，包括开通服务空间等。
3. `HBuilder X`里面，选中`uniCloud`，右键 -> 关联云服务空间或项目(目前使用的是阿里云)
4. `HBuilder X`里面，选中`uniCloud/database`，右键 -> 上传所有 DB Schema（含扩展）
5. `HBuilder X`里面，选中`uniCloud/cloudfunctions/wf-push-url`，右键 -> 运行本地云函数，查看日志`收到推送消息`
6. `HBuilder X`里面，选中`uniCloud/cloudfunctions/wf-push-url`，右键 -> 上传部署
7. 进入服务空间后台，云函数列表，添加域名
8. 进入服务空间，云函数/云对象 -> 云函数/云对象, 点击`wf-push-url`，云函数 URL 化，设置 URL 的 PATH 部分为`/push`
9. 可通过 postman，或者 curl 进行测试，地址是 `http(s)://${上面添加的域名}/push`
    ```
    curl --location 'http://{你添加的域名}/push' \
    --header 'X-User-Id: 你的用户 id' \
    --header 'Content-Type: application/json' \
    --data '{
        "clientId": "your push clientId, 应用启动的时候会打印出来",
        "title": "test push title",
        "content": "test push content",
        "payload": {
            "test": "test payload"
        },
        "category": {
            "harmony": "IM",
            "huawei": "IM",
            "vivo": "IM"
        }
    }'
    ```
10. 编译、配置、部署 [push server](https://github.com/wildfirechat/push_server)
11. `App.vue` 里面会调用`plus.push.getClientInfoAsync`获取推送相关的`clientId`，可以使用该`clientId`在`uni-push`后台测试推送功能。
12. 当设备不在线时，`im-server`会调用`push-server`，然后`push-server`调用`uniCloud`进行推送


## 常见问题说明

1. 如果希望普通电话，能打断音视频通话，则需要在`package.json`里面，添加如下权限声明:
    ```xml
       <uses-permission android:name="android.permission.PROCESS_OUTGOING_CALLS" />
    ```

## 应用截图

会话列表
![会话列表](./screenshots/uniapp_conversation_list.jpeg)

联系人列表
![联系人列表](./screenshots/uniapp_contact_tab.jpeg)

会话界面
![会话界面](./screenshots/uniapp_conversation.jpeg)

用户详情界面
![用户详情界面](./screenshots/uniapp_user_profile.jpeg)
