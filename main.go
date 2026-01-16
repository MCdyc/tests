package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/lni/dragonboat/v4"
	"github.com/lni/dragonboat/v4/config"
	"github.com/lni/dragonboat/v4/logger"
)

// 命令行参数
var (
	nodeID   = flag.Int("nodeid", 1, "Raft Node ID")
	addr     = flag.String("addr", "127.0.0.1:30001", "Raft 内部通信地址 (IP:Port)")
	httpAddr = flag.String("http", ":21001", "HTTP API 监听地址 (IP:Port)")
	join     = flag.Bool("join", false, "是否加入现有集群")
)

func main() {
	flag.Parse()

	// 降低日志级别
	logger.GetLogger("raft").SetLevel(logger.ERROR)
	logger.GetLogger("rsm").SetLevel(logger.ERROR)
	logger.GetLogger("transport").SetLevel(logger.ERROR)

	// 1. Dragonboat 配置 (注意 v4 API 变更: NodeID -> ReplicaID, ClusterID -> ShardID)
	rc := config.Config{
		ReplicaID:          uint64(*nodeID), // 变更点 1
		ShardID:            128,             // 变更点 2
		ElectionRTT:        10,
		HeartbeatRTT:       1,
		CheckQuorum:        true,
		SnapshotEntries:    10000,
		CompactionOverhead: 5000,
	}

	dataDir := filepath.Join("dragonboat-data", fmt.Sprintf("node%d", *nodeID))
	nhc := config.NodeHostConfig{
		WALDir:         dataDir,
		NodeHostDir:    dataDir,
		RTTMillisecond: 50,
		RaftAddress:    *addr,
	}

	// 2. 初始化 NodeHost
	nh, err := dragonboat.NewNodeHost(nhc)
	if err != nil {
		panic(err)
	}
	defer nh.Close()

	// 3. 定义集群成员
	initialMembers := map[uint64]string{
		1: "127.0.0.1:30001",
		2: "127.0.0.1:30002",
		3: "127.0.0.1:30003",
	}
	if *join {
		initialMembers = nil
	}

	// 4. 启动 Replica (v4 使用 StartReplica 替代 StartOnDiskCluster)
	// 注意：NewKVStateMachine 返回的是 IStateMachine，属于内存状态机范畴（虽然数据通过 SaveSnapshot 落地）
	if err := nh.StartReplica(initialMembers, *join, NewKVStateMachine, rc); err != nil {
		fmt.Fprintf(os.Stderr, "failed to start cluster: %v\n", err)
		os.Exit(1)
	}

	// 5. 启动 HTTP Server
	startHTTPServer(nh, rc.ShardID) // 使用 ShardID

	// 6. 等待退出信号
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	<-c
	fmt.Println("Shutting down...")
}

func startHTTPServer(nh *dragonboat.NodeHost, shardID uint64) {
	http.HandleFunc("/write", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		session := nh.GetNoOPSession(shardID)
		_, err = nh.SyncPropose(ctx, session, body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	http.HandleFunc("/read", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		// Rust客户端发送的是JSON格式的key，需要解析
		var key string
		if err := json.Unmarshal(body, &key); err != nil {
			// 如果解析失败，尝试直接使用body作为key
			key = string(body)
		}

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		val, err := nh.SyncRead(ctx, shardID, key)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}

		if val == nil {
			w.WriteHeader(http.StatusNotFound)
		} else {
			w.Write([]byte(val.(string)))
		}
	})

	http.HandleFunc("/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("{}"))
	})

	fmt.Printf("Dragonboat Server listening on HTTP %s (Raft %s)\n", *httpAddr, *addr)
	
	go func() {
		if err := http.ListenAndServe(*httpAddr, nil); err != nil {
			log.Fatal(err)
		}
	}()
}