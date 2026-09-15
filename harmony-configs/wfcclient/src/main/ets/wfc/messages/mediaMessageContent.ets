/*
 * Copyright (c) 2020 WildFireChat. All rights reserved.
 */

import MessageContent from './messageContent'
import MessagePayload from './messagePayload';

// 从 hm-chat 拷贝，去掉了 decode 里的 Config.urlRedirect（双网地址转换）：本适配层只用它发对讲的留底语音，
// 不给界面解码媒体消息，地址转换由 UTS 侧负责
export default class MediaMessageContent extends MessageContent {
    remotePath = '';
    localPath = '';
    mediaType = 0;

    /**
     *
     * @param {number} messageType 消息类型
     * @param {number} mediaType 媒体类型
     * @param {string} fileOrLocalPath 本地路径，必须是绝对路径
     * @param {string} remotePath 远端地址
     */
    constructor(messageType: number, mediaType = 0, fileOrLocalPath = '', remotePath = '') {
        super(messageType);
        this.mediaType = mediaType;
        if (!fileOrLocalPath) {
            this.localPath = '';
            this.remotePath = remotePath;
        } else if (typeof fileOrLocalPath === "string" && !fileOrLocalPath.startsWith("http")) {
            this.localPath = fileOrLocalPath;
            this.remotePath = remotePath;
        } else {
            throw new Error('invalid parameter')
        }
    }

    encode() {
        let payload = super.encode();
        payload.localMediaPath = this.localPath;
        payload.remoteMediaUrl = this.remotePath ? this.remotePath : '';
        payload.mediaType = this.mediaType;
        return payload;
    }

    decode(payload: MessagePayload) {
        super.decode(payload);
        this.localPath = payload.localMediaPath;
        this.remotePath = payload.remoteMediaUrl;
        this.mediaType = payload.mediaType;
    }
}
