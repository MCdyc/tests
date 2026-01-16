@echo off
setlocal EnableDelayedExpansion

:: ================= 配置 =================
set DIST_DIR=dist-dragonboat
set SERVER_SRC=main.go
set SERVER_EXE=dragonboat-server.exe
set BENCH_EXE=bench.exe

echo [打包] 1/5 正在清理环境...
:: 清理 Go
if exist "%SERVER_EXE%" del "%SERVER_EXE%"
:: 清理 Rust (bench 目录)
pushd bench
cargo clean
popd

echo [打包] 2/5 正在编译 Go Server...
:: 使用用户指定的命令编译
go build -o %SERVER_EXE% .
if %errorlevel% neq 0 ( echo [错误] Go 编译失败 & exit /b 1 )

echo [打包] 3/5 正在编译 Rust Client (静态链接CRT)...
pushd bench
:: Rust 静态链接设置
set RUSTFLAGS=-C target-feature=+crt-static
cargo build --release
if %errorlevel% neq 0 ( popd & echo [错误] Rust 编译失败 & exit /b 1 )
popd

echo [打包] 4/5 准备分发目录...
if exist "%DIST_DIR%" rd /s /q "%DIST_DIR%"
mkdir "%DIST_DIR%"

echo [打包] 5/5 复制文件与生成脚本...
:: 复制 Go 二进制
if exist "%SERVER_EXE%" (
    copy "%SERVER_EXE%" "%DIST_DIR%\" >nul
) else (
    echo [错误] 找不到 %SERVER_EXE%
    exit /b 1
)

:: 复制 Rust 二进制
if exist "bench\target\release\%BENCH_EXE%" (
    copy "bench\target\release\%BENCH_EXE%" "%DIST_DIR%\" >nul
) else (
    echo [错误] 找不到 bench\target\release\%BENCH_EXE%
    exit /b 1
)

:: 生成便携版启动脚本
(
echo @echo off
echo setlocal EnableDelayedExpansion
echo.
echo :: ================= 配置 =================
echo set SERVER_BIN=%SERVER_EXE%
echo set BENCH_BIN=%BENCH_EXE%
echo.
echo set NODE1_RAFT=127.0.0.1:30001
echo set NODE1_HTTP=127.0.0.1:21001
echo set NODE2_RAFT=127.0.0.1:30002
echo set NODE2_HTTP=127.0.0.1:21002
echo set NODE3_RAFT=127.0.0.1:30003
echo set NODE3_HTTP=127.0.0.1:21003
echo.
echo :: 接收参数
echo if "%%1"=="clean" goto clean
echo goto run
echo.
echo :cleanup
echo    echo [清理] 停止旧进程...
echo    taskkill /F /IM "%%SERVER_BIN%%" /T ^>nul 2^>^&1
echo    echo [清理] 删除 Dragonboat 数据目录...
echo    if exist "dragonboat-data" ^(
echo        rd /s /q "dragonboat-data"
echo    ^)
echo    timeout /t 3 /nobreak ^>nul
echo    exit /b 0
echo.
echo :start_cluster
echo    if not exist "%%SERVER_BIN%%" ^(
echo        echo 错误: 找不到 %%SERVER_BIN%%
echo        exit /b 1
echo    ^)
echo    echo [集群] 启动 Node 1...
echo    start /b "" "%%SERVER_BIN%%" -nodeid 1 -addr %%NODE1_RAFT%% -http :21001 ^> node1.log 2^>^&1
echo    timeout /t 3 /nobreak ^>nul
echo    echo [集群] 启动 Node 2...
echo    start /b "" "%%SERVER_BIN%%" -nodeid 2 -addr %%NODE2_RAFT%% -http :21002 ^> node2.log 2^>^&1
echo    timeout /t 3 /nobreak ^>nul
echo    echo [集群] 启动 Node 3...
echo    start /b "" "%%SERVER_BIN%%" -nodeid 3 -addr %%NODE3_RAFT%% -http :21003 ^> node3.log 2^>^&1
echo    timeout /t 3 /nobreak ^>nul
echo    echo [集群] 等待选主 ^(10秒^)...
echo    timeout /t 10 /nobreak ^>nul
echo    echo [集群] 检查 Leader 连通性...
echo    curl -s http://%%NODE1_HTTP%%/read -d "test_check" ^>nul 2^>^&1
echo    if %%errorlevel%% neq 0 ^(
echo        echo 警告: 无法连接到 Node 1，请查看 node1.log。
echo    ^) else ^(
echo        echo [集群] 集群似乎已就绪。
echo    ^)
echo    exit /b 0
echo.
echo :run_benchmark
echo    echo [测试] 运行 Rust 客户端压测...
echo    if not exist "%%BENCH_BIN%%" ^(
echo        echo 错误: 找不到测试工具 %%BENCH_BIN%%
echo        exit /b 1
echo    ^)
echo    "%%BENCH_BIN%%" --server http://%%NODE1_HTTP%% --clients 200 --requests 10000 --test-type write 
echo    exit /b 0
echo.
echo :run
echo    call :cleanup
echo    call :start_cluster
echo    call :run_benchmark
echo    echo.
echo    echo ========================================
echo    echo  测试结束
echo    echo ========================================
echo    echo 提示: 使用 'start_portable.bat clean' 清理数据
echo    pause
echo    call :cleanup
echo    exit /b 0
echo.
echo :clean
echo    call :cleanup
echo    exit /b 0
) > "%DIST_DIR%\start_portable.bat"

echo.
echo ========================================
echo  Dragonboat 打包完成！
echo  文件位于: %DIST_DIR%\
echo ========================================
pause