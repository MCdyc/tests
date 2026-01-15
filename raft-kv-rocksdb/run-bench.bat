@echo off
setlocal EnableDelayedExpansion

:: =================配置=================
set LEADER_ADDR=127.0.0.1:21001
set NODE2_ADDR=127.0.0.1:21002
set NODE3_ADDR=127.0.0.1:21003
set LOG_LEVEL=info

:: 二进制文件名称
set SERVICE_NAME=raft-key-value-rocks.exe
:: 源码路径 (根据实际情况调整反斜杠)
set SOURCE_DIR=..\raft-kv-rocksdb

set LIBCLANG_PATH=D:\Path\LLVM\bin

:: 接收参数，默认为 run
if "%1"=="" goto run
if "%1"=="run" goto run
if "%1"=="status" goto status
if "%1"=="clean" goto clean
if "%1"=="help" goto help
echo 未知命令: %1
exit /b 1

:: =================功能模块=================

:cleanup
    echo [清理] 停止所有 %SERVICE_NAME% 进程...
    :: /F 强制终止, /IM 镜像名称, /T 终止子进程, >nul 屏蔽错误输出(如进程不存在时)
    taskkill /F /IM "%SERVICE_NAME%" /T >nul 2>&1
    taskkill /F /IM "bench.exe" /T >nul 2>&1
    
    echo [清理] 删除旧数据...
    del /Q 127.0.0.1_*.db >nul 2>&1
    del /Q *.log >nul 2>&1
    echo [清理] 完成
    exit /b 0

:build
    echo [构建] 编译项目 (内存版)...
    :: 假设 gcc 库已在 PATH 中，否则需手动 set PATH=...
    set CXXFLAGS=
    cargo build --release --manifest-path "%SOURCE_DIR%\Cargo.toml"
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
    if exist "%SOURCE_DIR%\target\release\%SERVICE_NAME%" (
        set BIN_PATH=%SOURCE_DIR%\target\release\%SERVICE_NAME%
    ) else if exist ".\target\release\%SERVICE_NAME%" (
        set BIN_PATH=.\target\release\%SERVICE_NAME%
    ) else (
        echo 错误: 找不到二进制文件 %SERVICE_NAME%
        exit /b 1
    )

    echo [集群] 使用二进制文件: %BIN_PATH%
    echo [集群] 启动节点1 (Leader)...
    
    :: 设置环境变量并后台启动
    set RUST_LOG=%LOG_LEVEL%
    start /b "" "%BIN_PATH%" --id 1 --http-addr %LEADER_ADDR% > node1.log 2>&1
    
    timeout /t 3 /nobreak >nul
    
    echo [集群] 初始化集群...
    curl -X POST http://%LEADER_ADDR%/init -H "Content-Type: application/json" -d "[]" >nul 2>&1
    
    echo [集群] 启动节点2...
    start /b "" "%BIN_PATH%" --id 2 --http-addr %NODE2_ADDR% > node2.log 2>&1
    
    timeout /t 3 /nobreak >nul
    
    echo [集群] 添加节点2为learner...
    :: 注意：Windows CMD 中 JSON 内部的双引号需要转义为 \"
    curl -X POST http://%LEADER_ADDR%/add-learner -H "Content-Type: application/json" -d "[2, \"%NODE2_ADDR%\"]" >nul 2>&1
    
    echo [集群] 启动节点3...
    start /b "" "%BIN_PATH%" --id 3 --http-addr %NODE3_ADDR% > node3.log 2>&1
    
    timeout /t 3 /nobreak >nul
    
    echo [集群] 添加节点3为learner...
    curl -X POST http://%LEADER_ADDR%/add-learner -H "Content-Type: application/json" -d "[3, \"%NODE3_ADDR%\"]" >nul 2>&1
    
    echo [集群] 变更集群成员资格...
    curl -X POST http://%LEADER_ADDR%/change-membership -H "Content-Type: application/json" -d "[1, 2, 3]" >nul 2>&1
    
    timeout /t 5 /nobreak >nul
    
    echo [集群] 完成
    echo [集群] Leader: http://%LEADER_ADDR%
    
    echo [集群] 写入测试数据...
    :: JSON 复杂对象的转义：最外层用双引号，内部 Key/Value 的双引号用 \" 转义
    curl -X POST http://%LEADER_ADDR%/write -H "Content-Type: application/json" -d "{\"Set\":{\"key\":\"test_key\",\"value\":\"test_value\"}}" >nul 2>&1
    echo [集群] 测试数据写入完成
    exit /b 0

:run_benchmark
    echo [测试] 运行性能测试...
    :: 同样是 start /b 或者直接运行（此处直接运行以便等待结束）
    .\bench\target\release\bench.exe --server http://%LEADER_ADDR% --clients 10 --requests 100 --test-type write --write-ratio 0.5
    echo [测试] 完成
    exit /b 0

:show_cluster_status
    echo [状态] 获取集群指标...
    :: 注意: Windows 默认没有 jq，如果没有安装 jq，这行会报错。
    :: 如果没有 jq，建议去掉 "| jq" 或者提示用户安装。
    curl -s POST http://%LEADER_ADDR%/metrics
    exit /b 0

:: =================主流程=================

:run
    echo ========================================
    echo  Raft-KV-Memstore (内存版) 性能测试
    echo ========================================
    
    call :cleanup
    call :build
    if %errorlevel% neq 0 exit /b %errorlevel%
    call :start_cluster
    
    echo.
    echo ========================================
    echo  集群已启动，开始性能测试...
    echo ========================================
    
    call :run_benchmark
    
    echo.
    echo ========================================
    echo  测试完成!
    echo ========================================
    exit /b 0

:clean
    call :cleanup
    exit /b 0

:status
    call :show_cluster_status
    exit /b 0

:help
    echo 使用方法: run-bench.bat [命令]
    echo 命令列表: run (默认), status, clean, help
    exit /b 0