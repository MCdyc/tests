@echo off
setlocal EnableDelayedExpansion

:: ================= 配置 =================
:: Go 服务端文件名
set SERVER_BIN=dragonboat-server.exe
:: Rust 客户端路径 (请根据实际情况修改路径)
set BENCH_BIN=bench\target\release\bench.exe

:: 端口配置 (必须与 main.go 中的 initialMembers 对应)
set NODE1_RAFT=127.0.0.1:63001
set NODE1_HTTP=127.0.0.1:21001

set NODE2_RAFT=127.0.0.1:63002
set NODE2_HTTP=127.0.0.1:21002

set NODE3_RAFT=127.0.0.1:63003
set NODE3_HTTP=127.0.0.1:21003

:: 接收参数
if "%1"=="" goto run
if "%1"=="clean" goto clean
echo 未知命令: %1
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
        echo 错误: 找不到 %SERVER_BIN%，请先执行 go build -o %SERVER_BIN% .
        exit /b 1
    )

    echo [集群] 启动 Node 1 (ID=1, HTTP=:21001)...
    start /b "" "%SERVER_BIN%" -nodeid 1 -addr %NODE1_RAFT% -http :21001 > node1.log 2>&1
    
    echo [集群] 启动 Node 2 (ID=2, HTTP=:21002)...
    start /b "" "%SERVER_BIN%" -nodeid 2 -addr %NODE2_RAFT% -http :21002 > node2.log 2>&1
    
    echo [集群] 启动 Node 3 (ID=3, HTTP=:21003)...
    start /b "" "%SERVER_BIN%" -nodeid 3 -addr %NODE3_RAFT% -http :21003 > node3.log 2>&1

    echo [集群] 等待选主 (10秒)...
    timeout /t 10 /nobreak >nul
    
    :: 简单的健康检查
    echo [集群] 检查 Leader 连通性...
    curl -s http://%NODE1_HTTP%/read -d "test_check" >nul 2>&1
    if %errorlevel% neq 0 (
        echo 警告: 无法连接到 Node 1，集群可能未启动成功。请查看 node1.log。
    ) else (
        echo [集群] 集群似乎已就绪。
    )
    exit /b 0

:run_benchmark
    echo [测试] 运行 Rust 客户端压测...
    cd bench
    cargo build --release
    cd ..
    if not exist "%BENCH_BIN%" (
        echo 错误: 找不到测试工具 %BENCH_BIN%
        echo 请检查路径或执行 cargo build --release
        exit /b 1
    )

    :: 运行参数: 200 客户端, 每个 10000 请求, 写操作
    "%BENCH_BIN%" --server http://%NODE1_HTTP% --clients 200 --requests 10000 --test-type write 
    
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