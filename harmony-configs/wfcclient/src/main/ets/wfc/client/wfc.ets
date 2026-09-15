/*
 * Copyright (c) 2020 WildFireChat. All rights reserved.
 */

import util from '@ohos.util';
import protoProxy, { sendMessageEx } from '@wfc/marswrapper';

import Long from '../util/long';
import Conversation from '../model/conversation';
import GroupInfo from '../model/groupInfo';
import GroupMember from '../model/groupMember';
import NullGroupInfo from '../model/nullGroupInfo';
import Message from '../messages/message';
import MessageContent from '../messages/messageContent';
import MessagePayload from '../messages/messagePayload';
import {
    CallbackWithValue_1_OrNull,
    CallbackWithValue_2_OrNull,
    FailCallback,
    FailCallbackOrNull,
    SuccessCallback
} from '../type/types';

const TAG = 'wfc-client-shim';

const base64Helper = new util.Base64Helper();
const textEncoder = new util.TextEncoder('utf-8');
const textDecoder = util.TextDecoder.create('utf-8');

export type ReceiveMessageListener = (messages: Message[], hasMore: boolean) => void;

/**
 * `wfc.eventEmitter` 的极简实现。目前只有 @wfc/ptt 在上面监听 `EventType.ReceiveMessage`，所以只支持这一种签名。
 *
 * hm-chat 里它就是 ability 的 eventHub。本适配层收不到原生回调，事件是插件桥接层喂进来的
 * （uni_modules/wfc-ptt-client/utssdk/app-harmony/pttBridge.ets）。
 * 不直接用 ability 的 eventHub：avenginekit 在那上面监听的也是 ReceiveMessage，
 * 两个 SDK 共用一个会互相收到对方的消息。
 */
export class WfcEventEmitter {
    private listeners: Map<string, ReceiveMessageListener[]> = new Map();

    on(event: string, listener: ReceiveMessageListener): void {
        let list = this.listeners.get(event);
        if (!list) {
            list = [];
            this.listeners.set(event, list);
        }
        if (list.indexOf(listener) < 0) {
            list.push(listener);
        }
    }

    off(event: string, listener: ReceiveMessageListener): void {
        const list = this.listeners.get(event);
        if (!list) {
            return;
        }
        const index = list.indexOf(listener);
        if (index >= 0) {
            list.splice(index, 1);
        }
    }

    emit(event: string, messages: Message[], hasMore: boolean): void {
        const list = this.listeners.get(event);
        if (!list) {
            return;
        }
        // 拷一份再遍历，回调里 off 不影响这一轮
        for (const listener of list.slice()) {
            listener(messages, hasMore);
        }
    }
}

// 字段名和 UTS 侧 wfc/model/groupInfo.uts#fromJsonObject 一致
function groupInfoFromJson(obj: Record<string, Object>): GroupInfo {
    const info = new GroupInfo();
    info.target = (obj.target ?? '') as string;
    info.name = (obj.name ?? '') as string;
    info.portrait = (obj.portrait ?? '') as string;
    info.owner = (obj.owner ?? '') as string;
    info.type = (obj.type ?? 0) as number;
    info.memberCount = (obj.memberCount ?? 0) as number;
    info.extra = (obj.extra ?? '') as string;
    info.remark = (obj.remark ?? '') as string;
    info.updateDt = (obj.updateDt ?? 0) as number;
    info.memberDt = (obj.memberDt ?? 0) as number;
    info.mute = (obj.mute ?? 0) as number;
    info.joinType = (obj.joinType ?? 0) as number;
    info.privateChat = (obj.privateChat ?? 0) as number;
    info.superGroup = (obj.superGroup ?? 0) as number;
    info.searchable = (obj.searchable ?? 0) as number;
    info.historyMessage = (obj.historyMessage ?? 0) as number;
    info.maxMemberCount = (obj.maxMemberCount ?? 0) as number;
    return info;
}

// 字段名和 UTS 侧 wfc/model/groupMember.uts#fromJsonObject 一致
function groupMemberFromJson(obj: Record<string, Object>): GroupMember {
    const member = new GroupMember();
    member.groupId = (obj.groupId ?? '') as string;
    member.memberId = (obj.memberId ?? '') as string;
    member.alias = (obj.alias ?? '') as string;
    member.extra = (obj.extra ?? '') as string;
    member.type = (obj.type ?? 0) as number;
    member.updateDt = (obj.updateDt ?? 0) as number;
    member.createDt = (obj.createDt ?? 0) as number;
    return member;
}

/**
 * @wfc/avenginekit 和 @wfc/ptt 依赖的 `@wfc/client` 门面，只实现它们真正调用到的方法，
 * 底层直接复用已经打进 App 的 `@wfc/marswrapper`（同一个 libmarswrapper.so 实例，
 * 与 UTS 侧 wfc-client 插件共用同一条连接）。整体说明见模块根目录 README.md。
 *
 * 注意：这里发出去的消息不会经过 UTS 侧 `wfc.uts` 的发送封装，
 * 因此不会触发 onSendPrepare/onSendSuccess 事件。这与 Android/iOS 上
 * 原生 AVEngineKit / PttClient 自行发消息的行为一致（通话消息、对讲的留底语音在重新加载会话时才出现在消息列表）。
 */
export class WfcClientShim {

    /**
     * 事件通知，见 {@link WfcEventEmitter}
     */
    eventEmitter: WfcEventEmitter = new WfcEventEmitter();

    getUserId(): string {
        // 注意：libmarswrapper.so 导出的是 getCurrentUserId，没有 getUserId
        // （UTS 侧 wfc-client 插件里那行 getUserId 是注释掉的，别照抄）
        return protoProxy.getCurrentUserId() as string;
    }

    /**
     * 服务器时间和本地时间的差值
     */
    getServerDeltaTime(): number {
        return protoProxy.getServerDeltaTime() as number;
    }

    /**
     * 只把消息类型的存储标记告诉协议栈。消息内容怎么构造，由调用方通过
     * MessageConfig.registerMessageContentFactory 注册
     */
    registerMessageContent(_name: string, flag: number, type: number): void {
        protoProxy.registerMessageFlag(type, flag);
    }

    getMessageByUid(messageUid: Long | string | number): Message | null {
        const str = protoProxy.getMessageByUid(Long.fromValue(messageUid).toString()) as string;
        if (!str) {
            return null;
        }
        try {
            return Message.fromProtoMessage(JSON.parse(str) as Record<string, Object>);
        } catch (e) {
            console.error(TAG, 'getMessageByUid parse failed', JSON.stringify(e));
            return null;
        }
    }

    updateMessageContent(messageId: number, messageContent: MessageContent): void {
        const payload: MessagePayload = messageContent.encode();
        protoProxy.updateMessage(messageId, JSON.stringify(payload));
    }

    /**
     * 发送消息。参数顺序与 hm-chat 的 wfc.sendConversationMessage 保持一致，
     * avenginekit / ptt 会按 (conversation, content, toUsers, null, null, null, successCB, failCB) 调用。
     */
    sendConversationMessage(conversation: Conversation, messageContent: MessageContent, toUsers: string[] = [],
        preparedCB: CallbackWithValue_2_OrNull<number, number> = null,
        progressCB: CallbackWithValue_2_OrNull<number, number> = null,
        uploadedCB: CallbackWithValue_1_OrNull<string> = null,
        successCB: CallbackWithValue_2_OrNull<Long, number> = null,
        failCB: FailCallbackOrNull = null): void {
        const payload: MessagePayload = messageContent.encode();
        const conversationStr = JSON.stringify(conversation);
        const payloadStr = JSON.stringify(payload);
        const onPrepared = (messageId: number, timestamp: number) => {
            preparedCB?.(messageId, timestamp);
        };
        const onProgress = (uploaded: number, total: number) => {
            progressCB?.(uploaded, total);
        };
        const onUploaded = (mediaUrl: string) => {
            uploadedCB?.(mediaUrl);
        };
        const onSuccess = (messageUid: string, timestamp: string) => {
            successCB?.(Long.fromValue(messageUid), Long.fromValue(timestamp).toNumber());
        };
        const onFail = (errorCode: number) => {
            console.error(TAG, 'send message failed', messageContent.type, errorCode);
            failCB?.(errorCode);
        };
        if (payload.localMediaPath && !payload.remoteMediaUrl) {
            // 带本地文件的媒体消息（对讲的留底语音）。开了对象存储时文件要先在 ArkTS 侧上传再发，
            // 这段逻辑在 marswrapper 给 uts 插件封装的 sendMessageEx 里（UTS 侧发语音消息走的也是它），
            // 直接调 native 的 sendMessage 会跳过上传
            sendMessageEx(conversationStr, payloadStr, toUsers, 0, onPrepared, onProgress, onUploaded, onSuccess, onFail);
            return;
        }
        protoProxy.sendMessage(conversationStr, payloadStr, toUsers, 0, onPrepared, onProgress, onUploaded, onSuccess,
            onFail);
    }

    /**
     * 会议信令（create_room/join_pub/mute/kick/leave/keepalive…）走独立的 conference request 通道，
     * 不是 IM 消息。avenginekit 只调 Ex 版本（普通版在它内部自己包了一层，会把 advance 传进来）。
     * 参数与 UTS 侧 wfc.uts#sendConferenceRequestEx 一一对应。
     */
    sendConferenceRequestEx(sessionId: string, roomId: string, request: string, data: string, advance: boolean,
        callback: ((errorCode: number, resp: string | null) => void) | null = null): void {
        // 注意 native 的参数顺序是 (sessionId, roomId, request, data, successCB, failCB, advance)，
        // advance 在最后，和 UTS 侧 wfc.uts 的签名不一样，别照着那边抄
        // （见 uni_modules/wfc-client/utssdk/app-harmony/index.uts#sendConferenceRequest）
        console.log('sendConferenceRequestEx', sessionId, roomId, request, data, advance)
        protoProxy.sendConferenceRequest('' + sessionId, roomId, request, data,
            (resp: string) => {
                callback?.(0, resp);
            },
            (errorCode: number) => {
                console.error(TAG, 'send conference request failed', request, errorCode);
                callback?.(errorCode, null);
            },
            advance);
    }

    /**
     * 不缓存：适配层收不到群信息更新的回调，缓存会拿到过期的全员禁言状态和群 extra（对讲配置在里面），
     * 每次直接查协议栈的本地库
     */
    getGroupInfo(groupId: string, refresh: boolean = false): GroupInfo {
        const str = protoProxy.getGroupInfo(groupId, refresh) as string;
        if (!str) {
            return new NullGroupInfo(groupId);
        }
        try {
            return groupInfoFromJson(JSON.parse(str) as Record<string, Object>);
        } catch (e) {
            console.error(TAG, 'getGroupInfo parse failed', groupId, JSON.stringify(e));
            return new NullGroupInfo(groupId);
        }
    }

    getGroupMember(groupId: string, memberId: string): GroupMember | null {
        const str = protoProxy.getGroupMember(groupId, memberId) as string;
        if (!str) {
            return null;
        }
        try {
            return groupMemberFromJson(JSON.parse(str) as Record<string, Object>);
        } catch (e) {
            console.error(TAG, 'getGroupMember parse failed', groupId, memberId, JSON.stringify(e));
            return null;
        }
    }

    /**
     * 只被 AddParticipants/MuteVideo 这类通知消息的 formatNotification 用到，
     * 而 avenginekit 从不调用 formatNotification（通知文案由 UTS 侧的消息类负责），
     * 这里返回 userId 兜底即可。
     */
    getGroupMemberDisplayName(_groupId: string, memberId: string): string {
        return memberId;
    }

    modifyGroupInfo(groupId: string, type: number, newValue: string, lines: number[],
        notifyMessageContent: MessageContent | null, successCB: SuccessCallback, failCB: FailCallback): void {
        // 和 UTS 侧 wfc.uts#modifyGroupInfo 一致：没有通知消息时传空串
        const payloadStr = notifyMessageContent ? JSON.stringify(notifyMessageContent.encode()) : '';
        protoProxy.modifyGroupInfo(groupId, type, newValue, lines, payloadStr,
            () => {
                successCB();
            },
            (errorCode: number) => {
                failCB(errorCode);
            });
    }

    getUserSetting(scope: number, key: string): string {
        return protoProxy.getUserSetting(scope, key) as string;
    }

    setUserSetting(scope: number, key: string, value: string, successCB: SuccessCallback, failCB: FailCallback): void {
        protoProxy.setUserSetting(scope, key, value,
            () => {
                successCB();
            },
            (errorCode: number) => {
                failCB(errorCode);
            });
    }

    /**
     * 应用锁，多个客户端抢同一个资源用（对讲抢麦）。duration 单位秒
     */
    requireLock(lockId: string, duration: number, successCB: SuccessCallback, failCB: FailCallback): void {
        protoProxy.requireLock(lockId, duration,
            () => {
                successCB();
            },
            (errorCode: number) => {
                failCB(errorCode);
            });
    }

    releaseLock(lockId: string, successCB: SuccessCallback, failCB: FailCallback): void {
        protoProxy.releaseLock(lockId,
            () => {
                successCB();
            },
            (errorCode: number) => {
                failCB(errorCode);
            });
    }

    utf8_to_b64(str: string): string {
        return base64Helper.encodeToStringSync(textEncoder.encodeInto(str));
    }

    b64_to_utf8(str: string): string {
        if (!str) {
            return '';
        }
        return textDecoder.decodeToString(base64Helper.decodeSync(str));
    }

    b64_to_arrayBuffer(str: string): ArrayBuffer {
        if (!str) {
            return new ArrayBuffer(0);
        }
        const bytes = base64Helper.decodeSync(str);
        return (bytes.buffer as ArrayBuffer).slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    }

    arrayBuffer_to_b64(data: ArrayBuffer): string {
        return base64Helper.encodeToStringSync(new Uint8Array(data));
    }
}

const self = new WfcClientShim();

export default self;
