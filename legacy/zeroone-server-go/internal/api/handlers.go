package api

import (
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/zeroone/server/internal/ids"
	"github.com/zeroone/server/internal/store"
)

// ---------- 设备 ----------

type deviceOut struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	Approved   bool       `json:"approved"`
	Current    bool       `json:"current"`
	LastSeenAt *time.Time `json:"lastSeenAt,omitempty"`
	RevokedAt  *time.Time `json:"revokedAt,omitempty"`
	CreatedAt  time.Time  `json:"createdAt"`
}

func toDeviceOut(d *store.Device, currentID string) deviceOut {
	return deviceOut{
		ID: d.ID, Name: d.Name, Platform: d.Platform, Approved: d.Approved(), Current: d.ID == currentID,
		LastSeenAt: d.LastSeenAt, RevokedAt: d.RevokedAt, CreatedAt: d.CreatedAt,
	}
}

func (s *Server) handleDeviceSelf(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	writeJSON(w, http.StatusOK, toDeviceOut(a.device, a.device.ID))
}

func (s *Server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	devices, err := s.store.ListDevices(r.Context(), a.session.UserID)
	if err != nil {
		s.internal(w, err)
		return
	}
	out := make([]deviceOut, 0, len(devices))
	for i := range devices {
		out = append(out, toDeviceOut(&devices[i], a.device.ID))
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": out})
}

// handleApproveDevice：已批准的设备为新设备放行（计划书 F-01 "已登录设备批准"）。
func (s *Server) handleApproveDevice(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	id := r.PathValue("id")
	if err := s.store.ApproveDevice(r.Context(), a.session.UserID, id, a.device.ID); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "设备不存在")
			return
		}
		s.internal(w, err)
		return
	}
	s.otps.Delete(id)
	s.audit(r.Context(), r, a.session.UserID, &id, "device_approved")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	id := r.PathValue("id")
	if id == a.device.ID {
		writeError(w, http.StatusBadRequest, "invalid_input", "不能移除当前设备，请使用退出登录")
		return
	}
	if err := s.store.RevokeDevice(r.Context(), a.session.UserID, id); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeError(w, http.StatusNotFound, "not_found", "设备不存在")
			return
		}
		s.internal(w, err)
		return
	}
	s.audit(r.Context(), r, a.session.UserID, &id, "device_revoked")
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleAudit(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	events, err := s.store.ListAudit(r.Context(), a.session.UserID, 100)
	if err != nil {
		s.internal(w, err)
		return
	}
	type eventOut struct {
		Event     string    `json:"event"`
		DeviceID  *string   `json:"deviceId,omitempty"`
		CreatedAt time.Time `json:"createdAt"`
	}
	out := make([]eventOut, 0, len(events))
	for _, e := range events {
		out = append(out, eventOut{Event: e.Event, DeviceID: e.DeviceID, CreatedAt: e.CreatedAt})
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": out})
}

// ---------- 同步 ----------

const (
	maxPushBatch = 500
	maxBlobBytes = 1 << 20
	pullDefault  = 500
	pullMax      = 1000
)

var validKinds = map[string]bool{"login": true, "card": true, "note": true, "identity": true}

type pushChangeIn struct {
	ItemID       string `json:"itemId"`
	VaultID      string `json:"vaultId"`
	Kind         string `json:"kind"`
	Blob         []byte `json:"blob"`
	BaseRevision int64  `json:"baseRevision"`
	Revision     int64  `json:"revision"`
	Deleted      bool   `json:"deleted"`
}

type pushReq struct {
	Changes []pushChangeIn `json:"changes"`
}

type pushResultOut struct {
	ItemID         string           `json:"itemId"`
	Status         store.PushStatus `json:"status"`
	Seq            int64            `json:"seq,omitempty"`
	ServerRevision int64            `json:"serverRevision"`
}

// handlePush 批量上行变更。每条变更按乐观锁独立裁决（计划书 S-07）：
//   - applied：baseRevision 与服务端一致，写入并追加 change_log
//   - duplicate：同版本同密文已存在（离线队列重放），幂等返回
//   - conflict：服务端已有更新版本，客户端需先 pull 再合并
func (s *Server) handlePush(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	var req pushReq
	if !decode(w, r, maxSyncBody, &req) {
		return
	}
	if len(req.Changes) == 0 || len(req.Changes) > maxPushBatch {
		writeError(w, http.StatusBadRequest, "invalid_input", "changes 数量需在 1-500 之间")
		return
	}
	results := make([]pushResultOut, 0, len(req.Changes))
	for i := range req.Changes {
		c := &req.Changes[i]
		switch {
		case !ids.ValidUUID(c.ItemID) || !ids.ValidUUID(c.VaultID):
			writeError(w, http.StatusBadRequest, "invalid_input", "itemId / vaultId 需为 UUID")
			return
		case !validKinds[c.Kind]:
			writeError(w, http.StatusBadRequest, "invalid_input", "未知条目类型")
			return
		case len(c.Blob) == 0 || len(c.Blob) > maxBlobBytes:
			writeError(w, http.StatusBadRequest, "invalid_input", "blob 大小不合法")
			return
		}
		res, err := s.store.PushItem(r.Context(), a.session.UserID, a.device.ID, &store.PushChange{
			ItemID: c.ItemID, VaultID: c.VaultID, Kind: c.Kind, Blob: c.Blob,
			BaseRevision: c.BaseRevision, Revision: c.Revision, Deleted: c.Deleted,
		})
		if err != nil {
			s.internal(w, err)
			return
		}
		results = append(results, pushResultOut{ItemID: res.ItemID, Status: res.Status, Seq: res.Seq, ServerRevision: res.ServerRevision})
	}
	writeJSON(w, http.StatusOK, map[string]any{"results": results})
}

type changeOut struct {
	Seq      int64      `json:"seq"`
	VaultID  string     `json:"vaultId"`
	Entity   string     `json:"entity"`
	EntityID string     `json:"entityId"`
	Op       string     `json:"op"`
	Revision int64      `json:"revision"`
	Item     *itemOut   `json:"item,omitempty"`
	At       time.Time  `json:"at"`
}

type itemOut struct {
	ID        string     `json:"id"`
	Kind      string     `json:"kind"`
	Blob      []byte     `json:"blob"`
	Revision  int64      `json:"revision"`
	DeviceID  string     `json:"deviceId"`
	DeletedAt *time.Time `json:"deletedAt,omitempty"`
	UpdatedAt time.Time  `json:"updatedAt"`
}

// handlePull 按游标增量拉取。同一实体的多次变更只下发当前快照，客户端据 revision 去重。
func (s *Server) handlePull(w http.ResponseWriter, r *http.Request) {
	a := sessionFrom(r.Context())
	since, err := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	if err != nil || since < 0 {
		since = 0
	}
	limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || limit <= 0 {
		limit = pullDefault
	}
	limit = min(limit, pullMax)
	changes, err := s.store.Pull(r.Context(), a.session.UserID, since, limit+1)
	if err != nil {
		s.internal(w, err)
		return
	}
	hasMore := len(changes) > limit
	if hasMore {
		changes = changes[:limit]
	}
	out := make([]changeOut, 0, len(changes))
	next := since
	for _, c := range changes {
		co := changeOut{Seq: c.Seq, VaultID: c.VaultID, Entity: c.Entity, EntityID: c.EntityID, Op: c.Op, Revision: c.Revision, At: c.CreatedAt}
		if c.Item != nil {
			co.Item = &itemOut{
				ID: c.Item.ID, Kind: c.Item.Kind, Blob: c.Item.Blob, Revision: c.Item.Revision,
				DeviceID: c.Item.DeviceID, DeletedAt: c.Item.DeletedAt, UpdatedAt: c.Item.UpdatedAt,
			}
		}
		out = append(out, co)
		next = c.Seq
	}
	writeJSON(w, http.StatusOK, map[string]any{"changes": out, "nextSeq": next, "hasMore": hasMore})
}
