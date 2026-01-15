# Raft-KV-RocksDB 性能测试指南

本指南介绍如何使用多客户端RPC性能测试工具对 Raft-KV-RocksDB 集群进行性能测试。

## 目录

1. [测试环境准备](#测试环境准备)
2. [启动Raft集群](#启动raft集群)
3. [运行性能测试](#运行性能测试)
4. [测试结果分析](#测试结果分析)
5. [测试参数说明](#测试参数说明)

## 测试环境准备

### 1. 编译项目

```bash
cd /home/star/document/rust/openraft/examples/raft-kv-rocksdb
CXXFLAGS="-include cstdint" cargo build --release
```

### 2. 编译性能测试工具

```bash
# 创建性能测试目录
mkdir -p bench

# 复制性能测试文件到bench目录
cp bench_rpc.rs bench/
cp Cargo.toml.bench bench/Cargo.toml

# 编译性能测试工具
cd bench
cargo build --release
```

## 启动Raft集群

### 1. 使用测试脚本启动集群

```bash
# 回到示例目录
cd /home/star/document/rust/openraft/examples/raft-kv-rocksdb

# 运行测试集群脚本
sh test-cluster.sh
```

**注意**：此脚本会自动创建一个3节点集群并执行一系列测试操作。测试完成后，所有节点将被终止。

### 2. 手动启动集群

如果你想手动启动集群进行性能测试，可以按照以下步骤操作：

#### 启动节点1（Leader）
```bash
RUST_LOG=info ./target/release/raft-key-value-rocks --id 1 --addr 127.0.0.1:21001 > node1.log 2>&1 &
```

#### 初始化集群
```bash
curl -X POST http://127.0.0.1:21001/init -H "Content-Type: application/json" -d "[]"
```

#### 启动节点2
```bash
RUST_LOG=info ./target/release/raft-key-value-rocks --id 2 --addr 127.0.0.1:21002 > node2.log 2>&1 &
```

#### 添加节点2为learner
```bash
curl -X POST http://127.0.0.1:21001/add-learner -H "Content-Type: application/json" -d "[2, \"127.0.0.1:21002\"]"
```

#### 启动节点3
```bash
RUST_LOG=info ./target/release/raft-key-value-rocks --id 3 --addr 127.0.0.1:21003 > node3.log 2>&1 &
```

#### 添加节点3为learner
```bash
curl -X POST http://127.0.0.1:21001/add-learner -H "Content-Type: application/json" -d "[3, \"127.0.0.1:21003\"]"
```

#### 变更集群成员资格
```bash
curl -X POST http://127.0.0.1:21001/change-membership -H "Content-Type: application/json" -d "[1, 2, 3]"
```

## 运行性能测试

### 1. 基本测试命令

```bash
# 进入性能测试目录
cd /home/star/document/rust/openraft/examples/raft-kv-rocksdb/bench

# 运行性能测试（默认配置：10个客户端，每个客户端1000个请求，混合读写）
./target/release/raft-kv-rocksdb-bench
```

### 2. 自定义测试参数

```bash
# 100个客户端，每个客户端10000个请求，仅测试写入性能
./target/release/raft-kv-rocksdb-bench --clients 100 --requests 10000 --test-type write

# 50个客户端，每个客户端5000个请求，混合读写（写入比例30%）
./target/release/raft-kv-rocksdb-bench --clients 50 --requests 5000 --test-type mixed --write-ratio 0.3

# 指定服务器地址（例如测试从节点的读取性能）
./target/release/raft-kv-rocksdb-bench --server http://127.0.0.1:21002 --test-type read
```

## 测试结果分析

### 测试结果示例

```
测试配置:
  服务器地址: http://127.0.0.1:21001
  客户端数量: 10
  每个客户端请求数: 1000
  测试类型: mixed
  写入/读取比例: 0.5

性能测试结果:
  总请求数: 10000
  总耗时: 5.23s
  吞吐量: 1912.05 req/s
  平均延迟: 5.23ms
  P50延迟: 4.12ms
  P95延迟: 12.56ms
  P99延迟: 28.78ms
  错误数: 0
```

### 关键指标解释

1. **总请求数**：测试期间发送的请求总数
2. **总耗时**：测试开始到结束的总时间
3. **吞吐量**：每秒处理的请求数（越高越好）
4. **平均延迟**：所有请求的平均响应时间
5. **P50/P95/P99延迟**：
   - P50：50%的请求响应时间小于此值
   - P95：95%的请求响应时间小于此值
   - P99：99%的请求响应时间小于此值
6. **错误数**：测试过程中发生的错误总数

## 测试参数说明

| 参数 | 缩写 | 默认值 | 说明 |
|------|------|--------|------|
| --server | - | http://127.0.0.1:21001 | 服务器地址（通常是leader节点） |
| --clients | -c | 10 | 并发客户端数量 |
| --requests | -r | 1000 | 每个客户端发送的请求数量 |
| --test-type | -t | mixed | 测试类型：write（仅写入）、read（仅读取）、mixed（混合） |
| --write-ratio | - | 0.5 | 写入请求比例（仅在mixed模式下有效，0.0-1.0之间） |

## 最佳实践

1. **逐步增加客户端数量**：从较少的客户端开始测试，逐步增加客户端数量，观察吞吐量和延迟的变化
2. **使用混合读写测试**：大多数实际应用场景都是混合读写，使用混合测试可以更真实地反映系统性能
3. **监控系统资源**：在测试期间监控CPU、内存和网络使用情况，了解系统瓶颈
4. **多次测试取平均值**：单次测试结果可能存在波动，建议多次测试取平均值
5. **测试不同集群规模**：可以尝试不同规模的集群（1、3、5节点），观察Raft协议在不同规模下的性能表现

## 清理测试环境

```bash
# 停止所有raft-key-value-rocks进程
pkill -f raft-key-value-rocks

# 删除测试数据
sudo rm -r 127.0.0.1:*.db
```

## 注意事项

1. 确保测试机器有足够的资源（CPU、内存、网络）来支持指定数量的客户端
2. 测试期间避免在同一机器上运行其他占用大量资源的程序
3. 在生产环境中部署时，请根据实际负载情况调整Raft配置参数
4. 对于大规模集群，建议在不同的物理机器上部署节点，以避免网络瓶颈
