# wfcclient —— 鸿蒙端 `@wfc/client` 适配层（源码）

> 本目录是**源码**，构建产物是 `harmony-configs/libs/wfcclient.har`。
> 改完源码后执行 `./build-har.sh` 重新生成 har，两者要一起提交。

## 这是什么

野火官方有两个鸿蒙 SDK 不是自包含的原生库，而是用 ArkTS 写的，并且在编译产物里**硬编码**了对
野火原生鸿蒙工程里 `@wfc/client` 模块的引用：

- **音视频** `@wfc/avenginekit`（`uni_modules/wfc-av-client/utssdk/app-harmony/libs/avenginekit.har`，
  取自 hm-chat 的 `uikit/libs/avenginekit.har`），一份 WebRTC 信令实现；
- **对讲** `@wfc/ptt`（`harmony-configs/libs/ptt.har`，取自 hm-chat 的 `uikit/libs/ptt.har`，
  源码在 `../hm-ptt` 的 `ptt` 模块），AMR 语音走 IM 透传消息。

两者引用到的文件合起来是：

```
@wfc/client                                             // wfc 单例
@wfc/client/src/main/ets/config                         // Config.ICE_SERVERS（avenginekit）
@wfc/client/src/main/ets/wfc/av/messages/*              // 各类 voip 信令消息（avenginekit）
@wfc/client/src/main/ets/wfc/client/{wfc,wfcEvent,messageConfig,userSettingScope}
@wfc/client/src/main/ets/wfc/messages/{message,messageContent,messageContentType,messagePayload,persistFlag,soundMessageContent}
@wfc/client/src/main/ets/wfc/model/{conversation,conversationType,userInfo,groupMemberType,modifyGroupInfoType,nullGroupInfo}
@wfc/client/src/main/ets/wfc/util/{long,longUtil}
@wfc/client/src/main/ets/wfc/type/types
```

本项目（uni-app x）的 IM 层是 UTS 写的（`wfc/**`），并不存在这样一个 ArkTS 包，
所以这里提供一个**最小适配层**：包名就叫 `@wfc/client`，目录结构与 hm-chat 的 client 模块
一一对应，但只实现这两个 SDK 真正用到的那一小部分。

## 为什么不直接把 hm-chat 的 client 模块搬过来

hm-chat 的 `client` 模块是完整的 IM SDK（156 个 .ets），并且自带一份
`libmarswrapper.so`。本项目已经通过 `libs/marswrapper.har` 打包了同一个 so，
搬过来会出现 so 重复打包、以及 `setReceiveMessageListener` 等单例监听器被覆盖的问题。

因此这里只保留纯数据/编解码相关的类（从 hm-chat 拷贝），
而 `wfc.ets` 门面只实现两个 SDK 用到的那几个方法，底层复用已经打进 App 的
`@wfc/marswrapper`（同一个 libmarswrapper.so 实例，和 UTS 侧共用一条连接）：

| 调用                                       | 调用方      | 本适配层实现                                               |
| ------------------------------------------ | ----------- | ---------------------------------------------------------- |
| `getUserId()`                              | 两者        | `marswrapper.getCurrentUserId()`                           |
| `getServerDeltaTime()`                     | 两者        | `marswrapper.getServerDeltaTime()`                         |
| `sendConversationMessage()`                | 两者        | `marswrapper.sendMessage()`，带本地文件的走 `sendMessageEx()` |
| `utf8_to_b64()` / `b64_to_utf8()`          | 两者        | `util.Base64Helper`                                        |
| `getMessageByUid(uid)`                     | avenginekit | `marswrapper.getMessageByUid()` + 本地解码                 |
| `updateMessageContent()`                   | avenginekit | `marswrapper.updateMessage()`                              |
| `sendConferenceRequestEx()`                | avenginekit | `marswrapper.sendConferenceRequest()`                      |
| `registerMessageContent()`                 | ptt         | `marswrapper.registerMessageFlag()`                        |
| `getGroupInfo()` / `getGroupMember()`      | ptt         | 同名 native 接口 + 本地解析，不缓存                        |
| `modifyGroupInfo()`                        | ptt         | 同名 native 接口（群 extra 里的对讲配置）                  |
| `getUserSetting()` / `setUserSetting()`    | ptt         | 同名 native 接口（静默收听）                               |
| `requireLock()` / `releaseLock()`          | ptt         | 同名 native 接口（抢麦）                                   |
| `arrayBuffer_to_b64()` / `b64_to_arrayBuffer()` | ptt    | `util.Base64Helper`（实时语音数据）                        |
| `eventEmitter.on/off(ReceiveMessage)`      | ptt         | 本适配层自己的 `WfcEventEmitter`，见「收消息」             |
| `MessageConfig.registerMessageContentFactory()` | ptt    | `client/messageConfig.ets`，`Message.fromProtoMessage` 先问它 |

> `sendConferenceRequestEx` 是会议版 avenginekit 才用到的（create_room / join_pub / mute /
> kick / leave / keepalive 等会议信令走这条通道，不是 IM 消息）。
> native 的参数顺序是 `(sessionId, roomId, request, data, successCB, failCB, advance)`，
> **advance 在最后**，和 UTS 侧 `wfc.uts#sendConferenceRequestEx` 的签名不一样，
> 以 `uni_modules/wfc-client/utssdk/app-harmony/index.uts` 为准。

> `sendConversationMessage` 遇到带本地文件、还没有远端地址的媒体消息（对讲的留底语音），改走 marswrapper
> 给 uts 插件封装的 `sendMessageEx`：开了对象存储（`isSupportBigFilesUpload`）时文件要先在 ArkTS 侧上传再发，
> 直接调 native 的 `sendMessage` 会跳过上传。UTS 侧发语音消息走的也是 `sendMessageEx`。
> 信令这类没有文件的消息仍然直接调 `sendMessage`，和之前一样。

## 为什么要打成 har，而不是当源码模块用

鸿蒙工程开了 `useNormalizedOHMUrl` 之后：

- **源码模块**（`build-profile.json5` 里的 module）必须被引用方在**自己的**
  `oh-package.json5` 里显式声明，只写在工程根 `oh-package.json5` 里不管用
  （实测报 `Failed to resolve OhmUrl ... @wfc/client`）；
- 而 uts 插件生成的 `oh-package.json5` 只能通过 `utssdk/app-harmony/config.json` 配置，
  config.json 里的相对路径又会被编译器夹到插件目录以内（见
  `@dcloudio/uni-uts-v1/dist/arkts/index.js` 的 `parsePackageDeps`），指不到本目录；
- **har 依赖**没有这个限制，连 avenginekit.har / ptt.har 内部的 `import '@wfc/client/...'` 也能正确解析。

## 为什么放在 harmony-configs/libs，而不是插件的 libs

`@wfc/client` 同时被 wfc-av-client 和 wfc-ptt-client 用到（`@wfc/ptt` 同理，被 wfc-ptt-client 和
wfc-voice-input 用到），所以 har 放在 `harmony-configs/libs/`，在工程根 `harmony-configs/oh-package.json5`
里各声明一次，和 `marswrapper.har` 一样：

- 生成的鸿蒙工程里，插件 config.json 里的依赖只链接进**该插件自己**的 `oh_modules`，别的插件看不到；
  工程根的依赖链接在根 `oh_modules`，所有插件都能解析（wfc-client 插件引用 `@wfc/marswrapper` 就是这样）；
- 每个插件各带一份的话，ohpm 会按路径装出两个同名同版本的包（`wfc` 单例、消息工厂可能被拆成两份，
  ptt.har 里的 .so 也会重复）。

## 收消息

两个 SDK 都收不到原生消息回调。消息是 UTS 侧 `wfc.uts` 收到的，它把原始 proto 消息通过
`EventType.ReceiveProtoMessages` 抛出来，再由各自的插件解码后喂给 SDK：

| SDK         | SDK 在哪监听 `EventType.ReceiveMessage`   | 转发链路                                                                          |
| ----------- | ----------------------------------------- | --------------------------------------------------------------------------------- |
| avenginekit | `setup(context)` 时，ability 的 eventHub  | `avEngineKit.uts` → 插件 `dispatchReceivedMessages()` → `messageBridge.ets`       |
| ptt         | `init()` 时，`wfc.eventEmitter`           | `wfc/ptt/pttClient.uts` → 插件 `dispatchReceivedMessages()` → `pttBridge.ets`     |

`wfc.eventEmitter` 是本适配层自己的极简 emitter，不是 ability 的 eventHub：两个 SDK 监听的是同名事件，
共用一个 eventHub 会互相收到对方的消息。

`messageBridge.ets` 里有一张 `VOIP_CONTENT_TYPES` 白名单，只有名单里的类型才会被解码后喂给引擎。
**升级 avenginekit 后如果它开始处理新的消息类型（比如会议版新增的 410 changeMode、411 kickoff），
要同时改三处**：白名单、`message.ets` 的 `createMessageContent`、以及对应的 `av/messages/*.ets`；
少改一处的表现是引擎收到消息但 `messageContent.callId` 是 undefined，静默不生效。

对讲的 21 ~ 24 四种消息类由 `@wfc/ptt` 在 init 时通过 `MessageConfig.registerMessageContentFactory` 自己注册，
`createMessageContent` 先问这些工厂，本适配层不用为它们拷消息类；`pttBridge.ets` 里同样只把这 4 种类型解码后喂进去。

## 维护提示

- 升级 `avenginekit.har` 或 `ptt.har` 后，先用 `grep -rhoE '@wfc/client[a-zA-Z0-9_/.]*'` 检查它引用的
  文件列表有没有变化，缺文件会在编译期报 `Unresolved reference` / `Failed to resolve OhmUrl`；
  再对一遍它调用的 `wfc.xxx` 方法，**缺方法编译期无感**（har 里是 js），运行到才报 `is not a function`。
- `messageContentType.ets` / `av/messages/*.ets` / `model/*.ets` 等文件是从 hm-chat 拷贝的，
  改动前先确认 hm-chat 那边是不是也变了，两边的编解码必须完全一致，否则信令无法互通。
  和 hm-chat 不一样的只有：`mediaMessageContent.ets` 去掉了 `Config.urlRedirect`，
  `groupMember.ets` 去掉了查用户信息的 `getName` / `getPortrait`。
- 本适配层发出去的消息（voip 信令、对讲的透传语音和留底语音）不经过 UTS 侧 `wfc.uts` 的发送封装，
  因此不会触发 onSendPrepare/onSendSuccess 事件。这与 Android/iOS 上原生 SDK 自行发消息的行为一致
  （Android/iOS 的 wfc-client 插件也不转发原生 SDK 发出的消息，要重新加载会话才会出现在消息列表里）。
