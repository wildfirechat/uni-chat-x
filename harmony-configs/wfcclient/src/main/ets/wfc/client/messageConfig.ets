/*
 * Copyright (c) 2020 WildFireChat. All rights reserved.
 */

import MessageContent from '../messages/messageContent';

export type MessageContentFactory = (type: number) => MessageContent | undefined;

/**
 * hm-chat client 里 MessageConfig 的子集，只保留「消息内容工厂」这个注册点。
 *
 * @wfc/ptt 在 init 时通过 registerMessageContentFactory 认领 21 ~ 24 这 4 种对讲消息，
 * Message.fromProtoMessage 解码时先问这里。
 */
export default class MessageConfig {
    private static messageContentFactories: MessageContentFactory[] = [];

    static registerMessageContentFactory(factory: MessageContentFactory) {
        if (MessageConfig.messageContentFactories.indexOf(factory) < 0) {
            MessageConfig.messageContentFactories.push(factory);
        }
    }

    /**
     * 用已注册的工厂创建消息内容，没有工厂认领这个类型时返回 undefined
     */
    static newExtensionMessageContent(type: number): MessageContent | undefined {
        for (const factory of MessageConfig.messageContentFactories) {
            let content = factory(type);
            if (content) {
                return content;
            }
        }
        return undefined;
    }
}
