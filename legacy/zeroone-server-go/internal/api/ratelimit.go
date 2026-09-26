package api

import (
	"net"
	"net/http"
	"sync"
	"time"
)

// rateLimiter 是按 key（通常为客户端 IP）的令牌桶。内测期单实例部署足够，
// 多实例时替换为 Redis 实现（计划书 §3.1 边缘层限流）。
type rateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    float64 // 每秒补充的令牌数
	burst   float64
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newRateLimiter(perMinute int, burst int) *rateLimiter {
	rl := &rateLimiter{buckets: map[string]*bucket{}, rate: float64(perMinute) / 60, burst: float64(burst)}
	go rl.gc()
	return rl
}

func (rl *rateLimiter) allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	now := time.Now()
	b, ok := rl.buckets[key]
	if !ok {
		b = &bucket{tokens: rl.burst, last: now}
		rl.buckets[key] = b
	}
	b.tokens = min(rl.burst, b.tokens+now.Sub(b.last).Seconds()*rl.rate)
	b.last = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

func (rl *rateLimiter) gc() {
	for range time.Tick(5 * time.Minute) {
		rl.mu.Lock()
		cutoff := time.Now().Add(-10 * time.Minute)
		for k, b := range rl.buckets {
			if b.last.Before(cutoff) {
				delete(rl.buckets, k)
			}
		}
		rl.mu.Unlock()
	}
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (rl *rateLimiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !rl.allow(clientIP(r)) {
			w.Header().Set("Retry-After", "30")
			writeError(w, http.StatusTooManyRequests, "rate_limited", "请求过于频繁，请稍后再试")
			return
		}
		next.ServeHTTP(w, r)
	})
}
