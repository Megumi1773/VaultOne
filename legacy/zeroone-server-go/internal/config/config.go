// Package config 从环境变量加载服务配置。
package config

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"time"
)

type Config struct {
	Addr         string
	DatabaseURL  string
	ServerSecret []byte
	TLSCert      string
	TLSKey       string
	SessionTTL   time.Duration
	CORSOrigins  []string
	DevMode      bool
}

func Load() (*Config, error) {
	c := &Config{
		Addr:        env("ZO_ADDR", ":8787"),
		DatabaseURL: os.Getenv("ZO_DATABASE_URL"),
		TLSCert:     os.Getenv("ZO_TLS_CERT"),
		TLSKey:      os.Getenv("ZO_TLS_KEY"),
		SessionTTL:  30 * 24 * time.Hour,
		DevMode:     os.Getenv("ZO_DEV") == "1",
	}
	if v := os.Getenv("ZO_SESSION_TTL_HOURS"); v != "" {
		h, err := strconv.Atoi(v)
		if err != nil || h <= 0 {
			return nil, fmt.Errorf("ZO_SESSION_TTL_HOURS 不合法: %q", v)
		}
		c.SessionTTL = time.Duration(h) * time.Hour
	}
	if s := os.Getenv("ZO_SERVER_SECRET"); s != "" {
		b, err := hex.DecodeString(s)
		if err != nil || len(b) < 32 {
			return nil, fmt.Errorf("ZO_SERVER_SECRET 需为 ≥32 字节的十六进制")
		}
		c.ServerSecret = b
	} else {
		if !c.DevMode {
			return nil, fmt.Errorf("生产模式必须设置 ZO_SERVER_SECRET（开发请设置 ZO_DEV=1）")
		}
		c.ServerSecret = make([]byte, 32)
		_, _ = rand.Read(c.ServerSecret)
		slog.Warn("未设置 ZO_SERVER_SECRET，已生成临时密钥：重启后邮箱索引失效，仅限开发使用")
	}
	return c, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
