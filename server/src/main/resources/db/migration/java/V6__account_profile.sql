-- 账户资料（计划书 §8.1 / §8.2）：昵称与头像。
--
-- 两个字段都是**用户可选的公开资料**，与密钥材料无关：
--   * `nickname` 只用于界面显示，默认空串表示未设置；
--   * `avatar` 存的是**地址**（http/https），不是图片本身——本部署没有对象存储，
--     而且 `users` 是 @Audited 实体，内联 base64 会被复制进每一版修订记录。
--
-- 两列都进 UserEntity 但**标 @NotAudited**：users_aud 是白名单（只审 vk_gen /
-- session_epoch / updated_at），资料字段不属于低频账户状态，不进修订表。
-- 因此本迁移**不需要**改 users_aud。
--
-- 用 NOT NULL DEFAULT '' 而不是可空：读取端不必区分 NULL 与空串，少一类边界。

ALTER TABLE users ADD COLUMN nickname TEXT NOT NULL DEFAULT '';
ALTER TABLE users ADD COLUMN avatar   TEXT NOT NULL DEFAULT '';
