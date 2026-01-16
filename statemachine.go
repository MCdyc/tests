package main

import (
	"encoding/json"
	"io"
	"sync"

	sm "github.com/lni/dragonboat/v4/statemachine"
)

// 对应 Rust 客户端发送的 JSON 结构: {"Set": {"key": "...", "value": "..."}}
type SetRequest struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

type OpenRaftRequest struct {
	Set *SetRequest `json:"Set,omitempty"`
}

// 简单的内存 KV 状态机
type KVStateMachine struct {
	mu   sync.RWMutex
	data map[string]string
}

func NewKVStateMachine(clusterID uint64, nodeID uint64) sm.IStateMachine {
	return &KVStateMachine{
		data: make(map[string]string),
	}
}

// === 修改点开始 ===
// 变更说明：v4 接口接收 sm.Entry，而不是 []byte
func (s *KVStateMachine) Update(entry sm.Entry) (sm.Result, error) {
	// 解析 Rust 客户端发来的 JSON
	// 注意：数据现在存储在 entry.Cmd 中
	var req OpenRaftRequest
	if err := json.Unmarshal(entry.Cmd, &req); err != nil {
		return sm.Result{}, err
	}

	if req.Set != nil {
		s.mu.Lock()
		s.data[req.Set.Key] = req.Set.Value
		s.mu.Unlock()
		// 返回 entry.Index 作为一个简单的结果标识（可选）
		return sm.Result{Value: entry.Index}, nil
	}
	return sm.Result{Value: 0}, nil
}
// === 修改点结束 ===

func (s *KVStateMachine) Lookup(query interface{}) (interface{}, error) {
	// 简单的读实现
	key, ok := query.(string)
	if !ok {
		return "", nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.data[key], nil
}

func (s *KVStateMachine) SaveSnapshot(w io.Writer, _ sm.ISnapshotFileCollection, _ <-chan struct{}) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return json.NewEncoder(w).Encode(s.data)
}

func (s *KVStateMachine) RecoverFromSnapshot(r io.Reader, _ []sm.SnapshotFile, _ <-chan struct{}) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return json.NewDecoder(r).Decode(&s.data)
}

func (s *KVStateMachine) Close() error { return nil }