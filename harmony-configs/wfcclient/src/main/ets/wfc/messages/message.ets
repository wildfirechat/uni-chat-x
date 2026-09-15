/*
 * Copyright (c) 2020 WildFireChat. All rights reserved.
 */

import Conversation from '../model/conversation';
import Long from '../util/long';
import MessageContent from './messageContent';
import MessagePayload from './messagePayload';
import MessageContentType from './messageContentType';
import NotificationMessageContent from './notification/notificationMessageContent';

import CallStartMessageContent from '../av/messages/callStartMessageContent';
import CallAnswerMessageContent from '../av/messages/callAnswerMessageContent';
import CallAnswerTMessageContent from '../av/messages/callAnswerTMessageContent';
import CallByeMessageContent from '../av/messages/callByeMessageContent';
import CallSignalMessageContent from '../av/messages/callSignalMessageContent';
import CallModifyMessageContent from '../av/messages/callModifyMessageContent';
import AddParticipantsMessageContent from '../av/messages/addParticipantsMessageContent';
import MuteVideoMessageContent from '../av/messages/muteVideoMessageContent';
import JoinCallRequestMessageContent from '../av/messages/joinCallRequestMessageContent';
import ConferenceChangeModeContent from '../av/messages/conferenceChangeModeContent';
import ConferenceKickoffMemberMessageContent from '../av/messages/conferenceKickoffMemberMessageContent';

import MessageConfig from '../client/messageConfig';

const TAG = 'wfc-client-shim';

/**
 * 先问 MessageConfig 里注册的工厂（@wfc/ptt 在 init 时认领 21 ~ 24 这 4 种对讲消息），
 * 再看 avenginekit 会处理的 voip 消息。其余类型（文本、图片、通知……）由 UTS 侧的
 * wfc.uts 负责解码，本适配层用基类 MessageContent 占位即可——avenginekit 和 @wfc/ptt 的
 * onReceiveMessage 都只按 messageContent.type 分支，命中不了就直接忽略。
 */
function createMessageContent(type: number): MessageContent {
    const extension = MessageConfig.newExtensionMessageContent(type);
    if (extension) {
        return extension;
    }
    switch (type) {
        case MessageContentType.VOIP_CONTENT_TYPE_START:
            return new CallStartMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_ACCEPT:
            return new CallAnswerMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_ACCEPT_T:
            return new CallAnswerTMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_END:
            return new CallByeMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_SIGNAL:
            return new CallSignalMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_MODIFY:
            return new CallModifyMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_ADD_PARTICIPANT:
            return new AddParticipantsMessageContent();
        case MessageContentType.VOIP_CONTENT_TYPE_MUTE_VIDEO:
            return new MuteVideoMessageContent();
        case MessageContentType.VOIP_Join_Call_Request:
            return new JoinCallRequestMessageContent();
        case MessageContentType.CONFERENCE_CONTENT_TYPE_CHANGE_MODE:
            return new ConferenceChangeModeContent();
        case MessageContentType.CONFERENCE_CONTENT_TYPE_KICKOFF_MEMBER:
            return new ConferenceKickoffMemberMessageContent();
        default:
            return new MessageContent(type);
    }
}

export default class Message {
    conversation: Conversation;
    from = '';
    content?: MessagePayload;
    messageContent: MessageContent;
    messageId = 0;
    direction = 0; // 0 out, 1 in
    status = 0;
    messageUid = Long.ZERO;
    timestamp = 0;
    to = '';
    localExtra = '';

    constructor(conversation: Conversation, messageContent: MessageContent) {
        this.conversation = conversation;
        this.messageContent = messageContent;
    }

    static fromProtoMessage(obj: Record<string, Object>): Message | null {
        if (!obj) {
            return null;
        }
        const objConv = obj.conversation as Record<string, Object>;
        if (!objConv || !objConv.target) {
            return null;
        }
        const convType = (objConv.type !== undefined ? objConv.type : objConv.conversationType) as number;
        const conversation = new Conversation(convType, objConv.target as string, (objConv.line ?? 0) as number);

        const payload = obj.content as MessagePayload;
        if (!payload) {
            return null;
        }
        const content = createMessageContent(payload.type);
        const msg = new Message(conversation, content);
        msg.content = payload;
        msg.messageId = Number(obj.messageId ?? 0);
        msg.direction = (obj.direction ?? 0) as number;
        msg.status = (obj.status ?? 0) as number;
        msg.to = (obj.to ?? '') as string;
        msg.localExtra = (obj.localExtra ?? '') as string;
        msg.messageUid = Long.fromValue(obj.messageUid as (string | number));
        // 移动端字段名是 serverTime
        const timestamp = obj.timestamp !== undefined ? obj.timestamp : obj.serverTime;
        msg.timestamp = timestamp === undefined ? 0 : Long.fromValue(timestamp as (string | number)).toNumber();
        // 移动端字段名是 sender
        msg.from = (obj.from ? obj.from : (obj.sender ?? '')) as string;

        try {
            content.decode(payload);
        } catch (error) {
            // voip 信令解不出来就当没收到，避免把半截内容喂给引擎
            console.error(TAG, 'decode message payload failed', payload.type, JSON.stringify(error));
            return null;
        }
        if (content instanceof NotificationMessageContent) {
            (content as NotificationMessageContent).fromSelf = msg.direction === 0;
        }
        return msg;
    }
}
