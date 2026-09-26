// Package notify 发送安全告警（登录、新设备、主密码变更、恢复）。
package notify

import (
	"context"
	"log/slog"
)

type Message struct {
	To      string
	Subject string
	Body    string
}

type Mailer interface {
	Send(ctx context.Context, m Message) error
}

// LogMailer 把邮件写入日志，供开发环境使用；生产替换为 SMTP / 云邮件服务实现。
type LogMailer struct{}

func (LogMailer) Send(_ context.Context, m Message) error {
	slog.Info("mail", "to", m.To, "subject", m.Subject, "body", m.Body)
	return nil
}
