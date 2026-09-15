/*
 * Copyright (c) 2020 WildFireChat. All rights reserved.
 */

// 从 hm-chat 拷贝，去掉了 getName / getPortrait：它们要查用户信息，本适配层不提供
export default class GroupMember {
    groupId = '';
    memberId = '';
    alias = '';
    extra = '';
    type = 0;
    updateDt = 0;
    createDt = 0;
}
