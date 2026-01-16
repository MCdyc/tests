@echo off
setlocal EnableDelayedExpansion

:: ================= 配置 =================
:: Go 服务器可执行文件
set SERVER_BIN=dragonboat-server.exe
:: Rust 基准测试路径 (注意路径为相对路径)
set BENCH_BIN=bench\target\release\bench.exe

:: 集群节点地址 (需与 main.go 中的 initialMembers 对应)
set NODE1_RAFT=127.0.0.1:30001
set NODE1_HTTP=127.0.0.1:21001

set NODE2_RAFT=127.0.0.1:30002
set NODE2_HTTP=127.0.0.1:21002

set NODE3_RAFT=127.0.0.1:30003
set NODE3_HTTP=127.0.0.1:21003

:: 处理命令行参数
if "%1"=="" goto run
if "%1"=="clean" goto clean
echo 未知参数: %1
exit /b 1

:: ================= 功能模块 =================

:cleanup
    echo [清理] 停止旧进程...
    taskkill /F /IM "%SERVER_BIN%" /T >nul 2>&1
    
    echo [清理] 删除 Dragonboat 数据目录...
    if exist "dragonboat-data" (
        rd /s /q "dragonboat-data"
    )
    timeout /t 3 /nobreak >nul
    echo [清理] 完成
    exit /b 0

:start_cluster
    if not exist "%SERVER_BIN%" (
        echo 错误: 找不到 %SERVER_BIN%，请确保已执行 go build -o %SERVER_BIN% .
        exit /b 1
    )

    echo [集群] 启动 Node 1 (ID=1, HTTP=:21001)...
    start /b "" "%SERVER_BIN%" -nodeid 1 -addr %NODE1_RAFT% -http :21001 > node1.log 2>&1
    
    echo [集群] 启动 Node 2 (ID=2, HTTP=:21002)...
    start /b "" "%SERVER_BIN%" -nodeid 2 -addr %NODE2_RAFT% -http :21002 > node2.log 2>&1
    
    echo [集群] 启动 Node 3 (ID=3, HTTP=:21003)...
    start /b "" "%SERVER_BIN%" -nodeid 3 -addr %NODE3_RAFT% -http :21003 > node3.log 2>&1

    echo [集群] 等待选举完成 (10秒)...
    timeout /t 10 /nobreak >nul
    
    :: 简单的 Leader 连通性检查
    echo [集群] 尝试连接 Leader 节点...
    curl -s http://%NODE1_HTTP%/read -d "test_check" >nul 2>&1
    if %errorlevel% neq 0 (
        echo 警告: 无法连接到 Node 1，集群可能未就绪，请检查 node1.log。
    ) else (
        echo [集群] 集群似乎已就绪
    )
    exit /b 0

:run_benchmark
    echo [基准] 开始 Rust 客户端压测...
    cd bench
    cargo build --release
    cd ..
    if not exist "%BENCH_BIN%" (
        echo 错误: 找不到编译后的文件 %BENCH_BIN%
        echo 请确保路径正确并执行 cargo build --release
        exit /b 1
    )

    :: 基准测试参数: 200 个客户端, 每个 10000 个请求, 写入测试
    "%BENCH_BIN%" --server http://%NODE1_HTTP% --clients 20 --requests 1000 --test-type mixed --write-ratio 0.5 
    
    exit /b 0

:: ================= 主流程 =================

:run
    call :cleanup
    call :start_cluster
    
    echo.
    echo ========================================
    echo  Dragonboat 集群已启动，开始压测...
    echo ========================================
    
    call :run_benchmark
    
    echo.
    echo ========================================
    echo  测试结束
    echo ========================================
    echo 提示: 使用 'run-bench-dragonboat.bat clean' 清理数据
    exit /b 0

:clean
    call :cleanup
    exit /b 0