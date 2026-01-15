#!/bin/bash
# export LD_LIBRARY_PATH=/usr/local/gcc-15.2.0/lib64:$LD_LIBRARY_PATH
set -o errexit
set -o nounset

# 配置
LEADER_ADDR="127.0.0.1:21001"
NODE2_ADDR="127.0.0.1:21002"
NODE3_ADDR="127.0.0.1:21003"
LOG_LEVEL="info"

# 二进制文件名称 (对应 Cargo.toml 中的 [[bin]] name)
SERVICE_NAME="raft-key-value"
# 源码路径
SOURCE_DIR="../../examples/raft-kv-memstore"

# 清理旧进程和数据
cleanup() {
    echo "[清理] 停止所有 $SERVICE_NAME 进程..."
    if [ "$(uname)" = "Darwin" ]; then
        if pgrep -xq -- "${SERVICE_NAME}"; then
            pkill -f "${SERVICE_NAME}"
        fi
    else
        set +e
        killall "${SERVICE_NAME}" 2>/dev/null || true
        set -e
    fi
    
    echo "[清理] 删除旧数据..."
    rm -rf 127.0.0.1:*.db || true
    echo "[清理] 完成"
}

# 编译项目
build() {
    echo "[构建] 编译项目 (内存版)..."
    # 使用 --manifest-path 指定编译子项目
    CXXFLAGS=cargo build --release --manifest-path "$SOURCE_DIR/Cargo.toml"
    
    echo "[构建] 编译性能测试工具..."
    cd bench
    cargo build --release
    cd ..
    echo "[构建] 完成"
}

# 启动集群
start_cluster() {
    # 查找二进制文件
    if [ -f "$SOURCE_DIR/target/release/$SERVICE_NAME" ]; then
        BIN_PATH="$SOURCE_DIR/target/release/$SERVICE_NAME"
    elif [ -f "./target/release/$SERVICE_NAME" ]; then
        BIN_PATH="./target/release/$SERVICE_NAME"
    else
        echo "错误: 找不到二进制文件 $SERVICE_NAME"
        exit 1
    fi

    echo "[集群] 使用二进制文件: $BIN_PATH"

    # === 关键修改: 将 --addr 替换为 --http-addr ===
    
    echo "[集群] 启动节点1 (Leader)..."
    RUST_LOG=$LOG_LEVEL $BIN_PATH --id 1 --http-addr $LEADER_ADDR 2>&1 > node1.log &
    NODE1_PID=$!
    
    sleep 3
    
    echo "[集群] 初始化集群..."
    curl -X POST http://$LEADER_ADDR/init -H "Content-Type: application/json" -d "[]" > /dev/null 2>&1
    
    echo "[集群] 启动节点2..."
    RUST_LOG=$LOG_LEVEL nohup $BIN_PATH --id 2 --http-addr $NODE2_ADDR > node2.log &
    NODE2_PID=$!
    
    sleep 3
    
    echo "[集群] 添加节点2为learner..."
    curl -X POST http://$LEADER_ADDR/add-learner -H "Content-Type: application/json" -d "[2, \"$NODE2_ADDR\"]" > /dev/null 2>&1
    
    echo "[集群] 启动节点3..."
    RUST_LOG=$LOG_LEVEL nohup $BIN_PATH --id 3 --http-addr $NODE3_ADDR > node3.log &
    NODE3_PID=$!
    
    sleep 3
    
    echo "[集群] 添加节点3为learner..."
    curl -X POST http://$LEADER_ADDR/add-learner -H "Content-Type: application/json" -d "[3, \"$NODE3_ADDR\"]" > /dev/null 2>&1
    
    echo "[集群] 变更集群成员资格..."
    curl -X POST http://$LEADER_ADDR/change-membership -H "Content-Type: application/json" -d "[1, 2, 3]" > /dev/null 2>&1
    
    sleep 5
    
    echo "[集群] 完成"
    echo "[集群] Leader: http://$LEADER_ADDR"
    
    # 写入测试数据
    echo "[集群] 写入测试数据..."
    curl -X POST http://$LEADER_ADDR/write -H "Content-Type: application/json" -d '{"Set":{"key":"test_key","value":"test_value"}}' > /dev/null 2>&1
    echo "[集群] 测试数据写入完成"
}

# 运行性能测试
run_benchmark() {
    echo "[测试] 运行性能测试..."
    # 内存版性能较高，使用 100 客户端，10000 请求
    ./bench/target/release/bench --server http://$LEADER_ADDR --clients 100 --requests 10000 --test-type write --write-ratio 0.5
    echo "[测试] 完成"
}

# 显示集群状态
show_cluster_status() {
    echo "[状态] 获取集群指标..."
    curl -s POST http://$LEADER_ADDR/metrics | jq
}

# 主流程
main() {
    echo "========================================"
    echo " Raft-KV-Memstore (内存版) 性能测试"
    echo "========================================"
    
    cleanup
    build
    start_cluster
    
    echo ""
    echo "========================================"
    echo " 集群已启动，开始性能测试..."
    echo "========================================"
    
    run_benchmark
    
    echo ""
    echo "========================================"
    echo " 测试完成!"
    echo "========================================"
}

# 命令处理
case ${1:-"run"} in
    "run")
        main
        ;;
    "status")
        show_cluster_status
        ;;
    "clean")
        cleanup
        ;;
    "help")
        echo "使用方法: ./run-bench.sh [命令]"
        ;;
    *)
        echo "未知命令: $1"
        exit 1
        ;;
esac