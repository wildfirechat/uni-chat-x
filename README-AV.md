# 音视频 SDK 使用说明

野火音视频 SDK 有两个版本，**对外接口完全一致**，本项目通过替换 SDK 文件在两者之间切换：

| | 多人版（免费） | 高级版 / 会议版 |
|---|---|---|
| 单聊音视频 | ✅ | ✅ |
| 多人（群）音视频 | ✅ | ✅ |
| 音视频会议 | ❌ | ✅ |
| 服务端依赖 | turn 服务 | 专业版 IM 服务 + [janus 服务](https://gitee.com/wfchat/wf-janus)（不需要 turn） |

两版的区别详见[野火音视频简介](https://docs.wildfirechat.cn/blogs/野火音视频简介.html)和[野火音视频使用说明](https://docs.wildfirechat.cn/webrtc/)。
高级版 SDK 需要联系野火官方获取。

## 代码里怎么判断

会议相关的接口在多人版 SDK 上**同样存在但不可用**（调用会失败或直接返回 null），
所以所有会议入口都必须先判断版本，不要靠编译期开关：

```ts
import avEngineKit from '@/wfc/av/engine/avEngineKit.uts'

avEngineKit.isSupportMultiCall()   // 多人音视频，两个版本都是 true
avEngineKit.isSupportConference()  // 会议，只有高级版是 true
```

项目里已经按这个约定接好了三处入口，换 SDK 之后不需要改代码：

- `pages/discovery/DiscoveryPage.uvue`：「会议」入口按 `isSupportConference()` 显隐；
- `pages/conversation/message/content/ConferenceInviteMessageContentView.uvue`：会议邀请消息，点了不支持时如实提示；
- `components/main-action-menu/main-action-menu.uvue`：扫会议二维码。

## 怎么换

三端各换各的文件，换完**必须重新制作自定义基座 / 云打包**，标准基座里带的是内置的那份。

### Android

`uni_modules/wfc-av-client/utssdk/app-android/libs/`

| 文件 | 说明 |
|---|---|
| `avenginekit.aar` | 当前正在使用的 |
| `avenginekit.aar-conference` | 高级版（会议版） |

切换到会议版：

```bash
cd uni_modules/wfc-av-client/utssdk/app-android/libs
cp avenginekit.aar avenginekit.aar-multi     # 先把当前这份多人版备份出来
cp avenginekit.aar-conference avenginekit.aar
```

### 鸿蒙

`uni_modules/wfc-av-client/utssdk/app-harmony/libs/`

| 文件 | 说明 |
|---|---|
| `avenginekit.har` | 当前正在使用的 |
| `avenginekit.har-multi` | 多人版 |
| `avenginekit.har-conference` | 高级版（会议版） |

```bash
cd uni_modules/wfc-av-client/utssdk/app-harmony/libs
cp avenginekit.har-conference avenginekit.har
```

> 鸿蒙版 SDK 是 ArkTS 实现的，还依赖 `harmony-configs/libs/wfcclient.har`（本项目自建的 `@wfc/client` 适配层，
> 和对讲插件共用，源码在 `harmony-configs/wfcclient/`）。换 avenginekit.har 不需要动它。

### iOS

`uni_modules/wfc-av-client/utssdk/app-ios/Frameworks/WFAVEngineKit.xcframework`
整个替换成官方给的高级版 xcframework。

## 会议功能涉及的文件

换成会议版之后会用到下面这些，多人版下它们照常编译，只是入口不出现：

```
uni_modules/wfc-av-client/utssdk/{app-android,app-ios,app-harmony}/index.uts
                                        原生插件层：startConference / joinConference /
                                        leaveConference / switchAudience / isSupportConference
wfc/av/engine/avEngineKit.uts           引擎门面
wfc/av/model/conferenceInfo.uts         会议信息模型
wfc/av/messages/conference*.uts         会议指令 / 模式切换 / 踢人消息
api/conferenceApi.uts                   app server 的 /conference/* 接口
pages/voip/conference/                  会议 UI（入口页、创建、预定、加入、详情、会议中、管理）
```

会议还依赖 **app server 的会议接口**（`/conference/create`、`/conference/info` 等）和
会议聊天室（会议指令走 ChatRoom 会话广播），服务端没部署会议服务时这些接口会失败。
