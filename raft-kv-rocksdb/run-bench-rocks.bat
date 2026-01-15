@echo off
setlocal EnableDelayedExpansion

:: ================= 配置 =================
set LEADER_ADDR=127.0.0.1:21001
set NODE2_ADDR=127.0.0.1:21002
set NODE3_ADDR=127.0.0.1:21003
set LOG_LEVEL=info
set LIBCLANG_PATH=D:\Path\LLVM\bin
:: 二进制文件名称 (根据 Cargo.toml)
set SERVICE_NAME=raft-key-value-rocks.exe
set BENCH_NAME=bench.exe

:: 接收参数
if "%1"=="" goto run
if "%1"=="run" goto run
if "%1"=="status" goto status
if "%1"=="clean" goto clean
if "%1"=="help" goto help
echo 未知命令: %1
exit /b 1

:: ================= 功能模块 =================

:cleanup
    echo [清理] 停止所有 %SERVICE_NAME% 进程...
    :: /F 强制, /IM 镜像名, /T 包含子进程
    taskkill /F /IM "%SERVICE_NAME%" /T >nul 2>&1
    taskkill /F /IM "%BENCH_NAME%" /T >nul 2>&1
    
    echo [清理] 删除旧数据...
    :: 删除可能存在的 RocksDB 数据目录 (Windows下通常是目录)
    :: 尝试删除带下划线的 (修复后代码产生的)
    for /d %%p in (127.0.0.1_*.db) do rd /s /q "%%p" >nul 2>&1
    :: 尝试删除带冒号的 (虽然 Windows 无法创建带冒号目录，但为了逻辑对应保留)
    for /d %%p in (127.0.0.1:*.db) do rd /s /q "%%p" >nul 2>&1
    
    :: 删除日志文件
    del /Q node*.log >nul 2>&1
    
    echo [清理] 完成
    exit /b 0

:build
    echo [构建] 编译项目...
    :: 设置 GCC 兼容标志 (如果使用 MSVC 可忽略，但保留无害)
    set CXXFLAGS=-include cstdint
    cargo build --release
    if %errorlevel% neq 0 exit /b %errorlevel%
    
    echo [构建] 编译性能测试工具...
    pushd bench
    cargo build --release
    if %errorlevel% neq 0 (
        popd
        exit /b %errorlevel%
    )
    popd
    echo [构建] 完成
    exit /b 0

:start_cluster
    :: 查找二进制文件
    if exist "target\release\%SERVICE_NAME%" (
        set BIN_PATH=target\release\%SERVICE_NAME%
    ) else if exist ".\target\release\%SERVICE_NAME%" (
        set BIN_PATH=.\target\release\%SERVICE_NAME%
    ) else (
        echo 错误: 找不到二进制文件 %SERVICE_NAME%
        echo 请先执行 build
        exit /b 1
    )

    echo [集群] 启动节点1 (Leader)...
    set RUST_LOG=%LOG_LEVEL%
    :: start /b 后台运行
    start /b "" "%BIN_PATH%" --id 1 --addr %LEADER_ADDR% > node1.log 2>&1
    
    :: 等待启动
    timeout /t 3 /nobreak >nul
    
    echo [集群] 初始化集群...
    curl -X POST http://%LEADER_ADDR%/init -H "Content-Type: application/json" -d "[]" >nul 2>&1
    
    echo [集群] 启动节点2...
    start /b "" "%BIN_PATH%" --id 2 --addr %NODE2_ADDR% > node2.log 2>&1
    
    timeout /t 3 /nobreak >nul
    
    echo [集群] 添加节点2为learner...
    :: Windows curl JSON 转义: 内部双引号变为 \"
    curl -X POST http://%LEADER_ADDR%/add-learner -H "Content-Type: application/json" -d "[2, \"%NODE2_ADDR%\"]" >nul 2>&1
    
    echo [集群] 启动节点3...
    start /b "" "%BIN_PATH%" --id 3 --addr %NODE3_ADDR% > node3.log 2>&1
    
    timeout /t 3 /nobreak >nul
    
    echo [集群] 添加节点3为learner...
    curl -X POST http://%LEADER_ADDR%/add-learner -H "Content-Type: application/json" -d "[3, \"%NODE3_ADDR%\"]" >nul 2>&1
    
    echo [集群] 变更集群成员资格...
    curl -X POST http://%LEADER_ADDR%/change-membership -H "Content-Type: application/json" -d "[1, 2, 3]" >nul 2>&1
    
    echo [集群] 等待集群稳定...
    timeout /t 5 /nobreak >nul
    
    echo [集群] 完成
    echo [集群] Leader: http://%LEADER_ADDR%
    
    echo [集群] 写入测试数据...
    :: 复杂 JSON 对象的转义
    curl -X POST http://%LEADER_ADDR%/write -H "Content-Type: application/json" -d "{\"Set\":{\"key\":\"test_key\",\"value\":\"test_value\"}}" >nul 2>&1
    echo [集群] 测试数据写入完成
    exit /b 0

:run_benchmark
    echo [测试] 运行性能测试...
    :: 对应 Linux: clients 200, requests 1000
    
    if not exist "bench\target\release\%BENCH_NAME%" (
        echo 错误: 找不到测试工具 bench\target\release\%BENCH_NAME%
        exit /b 1
    )

    bench\target\release\%BENCH_NAME% --server http://%LEADER_ADDR% --clients 200 --requests 10000 --test-type write --write-ratio 0.5
    
    echo [测试] 完成
    exit /b 0

:show_cluster_status
    echo [状态] 获取集群指标...
    :: 如果没有安装 jq，这行会报错，可以去掉 | jq 直接查看原始 JSON
    curl -s POST http://%LEADER_ADDR%/metrics | jq
    exit /b 0

:: ================= 主流程 =================

:run
    echo ========================================
    echo  Raft-KV-RocksDB 性能测试工具 (Windows)
    echo ========================================
    
    call :cleanup
    call :build
    if %errorlevel% neq 0 exit /b %errorlevel%
    call :start_cluster
    if %errorlevel% neq 0 exit /b %errorlevel%
    
    echo.
    echo ========================================
    echo  集群已启动，开始性能测试...
    echo ========================================
    
    call :run_benchmark
    
    echo.
    echo ========================================
    echo  性能测试完成!
    echo ========================================
    echo.
    echo 可用命令:
    echo   run-bench.bat status    - 查看集群状态
    echo   run-bench.bat clean     - 清理环境
    exit /b 0

:clean
    call :cleanup
    exit /b 0

:status
    call :show_cluster_status
    exit /b 0

:help
    echo 使用方法: run-bench.bat [命令]
    echo.
    echo 命令:
    echo   run      - 构建项目、启动集群并运行性能测试 (默认)
    echo   status   - 查看集群状态 (需要 jq)
    echo   clean    - 清理旧进程和数据
    echo   help     - 显示此帮助信息
    exit /b 0