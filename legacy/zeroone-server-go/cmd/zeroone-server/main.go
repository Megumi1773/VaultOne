// ZeroOne 同步服务入口。
//
//	ZO_DEV=1 go run ./cmd/zeroone-server                    # 内存存储，开箱即用
//	ZO_DATABASE_URL=postgres://... go run ./cmd/zeroone-server  # PostgreSQL
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/zeroone/server/internal/api"
	"github.com/zeroone/server/internal/config"
	"github.com/zeroone/server/internal/memstore"
	"github.com/zeroone/server/internal/notify"
	"github.com/zeroone/server/internal/pgstore"
	"github.com/zeroone/server/internal/store"
)

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var st store.Store
	if cfg.DatabaseURL != "" {
		pg, err := pgstore.Open(ctx, cfg.DatabaseURL)
		if err != nil {
			return err
		}
		st = pg
		slog.Info("storage", "driver", "postgres")
	} else {
		if !cfg.DevMode {
			return errors.New("未配置 ZO_DATABASE_URL；如需内存存储请设置 ZO_DEV=1")
		}
		st = memstore.New()
		slog.Warn("storage", "driver", "memory", "note", "数据仅保存在进程内存中")
	}
	defer st.Close()

	srv, err := api.New(cfg, st, notify.LogMailer{})
	if err != nil {
		return err
	}
	httpServer := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("listening", "addr", cfg.Addr, "tls", cfg.TLSCert != "")
		if cfg.TLSCert != "" {
			errCh <- httpServer.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
		} else {
			errCh <- httpServer.ListenAndServe()
		}
	}()

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		slog.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	}
	return nil
}
