//! 多客户端RPC性能测试程序

use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

use clap::Parser;
use reqwest::Client;
use tokio::runtime::Builder;
use tokio::sync::Barrier;

/// 性能测试配置
#[derive(Parser, Debug)]
struct BenchConfig {
    /// 服务器地址 (leader节点)
    #[clap(long, default_value = "http://127.0.0.1:21001")]
    server: String,

    /// 客户端数量
    #[clap(short, long, default_value_t = 128)]
    clients: usize,

    /// 每个客户端的请求数量
    #[clap(short, long, default_value_t = 10000)]
    requests: usize,

    /// 测试类型: write, read, mixed
    #[clap(short, long, default_value = "write")]
    test_type: String,

    /// 写入/读取比例 (仅在mixed模式下有效)
    #[clap(long, default_value_t = 0.5)]
    write_ratio: f64,
}

/// 测试结果
struct BenchResult {
    total_requests: usize,
    total_time: Duration,
    throughput: f64,
    avg_latency: Duration,
    p50_latency: Duration,
    p95_latency: Duration,
    p99_latency: Duration,
    errors: usize,
}

impl BenchResult {
    fn new(total_requests: usize, total_time: Duration, latencies: &[Duration], errors: usize) -> Self {
        let mut latencies_sorted = latencies.to_vec();
        latencies_sorted.sort();

        let throughput = total_requests as f64 / total_time.as_secs_f64();
        let avg_latency = total_time / total_requests as u32;

        let p50 = latencies_sorted[(latencies_sorted.len() * 50) / 100];
        let p95 = latencies_sorted[(latencies_sorted.len() * 95) / 100];
        let p99 = latencies_sorted[(latencies_sorted.len() * 99) / 100];

        Self {
            total_requests,
            total_time,
            throughput,
            avg_latency,
            p50_latency: p50,
            p95_latency: p95,
            p99_latency: p99,
            errors,
        }
    }

    fn print(&self) {
        println!("性能测试结果:");
        println!("  总请求数: {}", self.total_requests);
        println!("  总耗时: {:?}", self.total_time);
        println!("  吞吐量: {:.2} req/s", self.throughput);
        println!("  平均延迟: {:?}", self.avg_latency);
        println!("  P50延迟: {:?}", self.p50_latency);
        println!("  P95延迟: {:?}", self.p95_latency);
        println!("  P99延迟: {:?}", self.p99_latency);
        println!("  错误数: {}", self.errors);
    }
}

/// 执行单个写入请求
async fn perform_write(client: &Client, server: &str, key: &str, value: &str) -> Result<Duration, reqwest::Error> {
    let start = Instant::now();

    let payload = serde_json::json!({"Set": {"key": key, "value": value}});
    client.post(format!("{}/write", server)).json(&payload).send().await?;

    Ok(start.elapsed())
}

/// 执行单个读取请求
async fn perform_read(client: &Client, server: &str, key: &str) -> Result<Duration, reqwest::Error> {
    let start = Instant::now();

    client.post(format!("{}/read", server)).json(key).send().await?;

    Ok(start.elapsed())
}

/// 客户端测试任务
async fn client_task(
    client_id: usize,
    client: Client,
    server: String,
    requests: usize,
    test_type: String,
    write_ratio: f64,
    barrier: Arc<Barrier>,
    counter: Arc<AtomicU64>,
    latencies: Arc<Vec<AtomicU64>>,
    errors: Arc<AtomicU64>,
) {
    // 等待所有客户端准备就绪
    barrier.wait().await;

    for i in 0..requests {
        let key = format!("key_{}_{}", client_id, i);
        let value = format!("value_{}_{}", client_id, i);

        let result = match test_type.as_str() {
            "write" => perform_write(&client, &server, &key, &value).await,
            "read" => perform_read(&client, &server, &key).await,
            "mixed" => {
                if rand::random::<f64>() < write_ratio {
                    perform_write(&client, &server, &key, &value).await
                } else {
                    perform_read(&client, &server, &key).await
                }
            }
            _ => panic!("未知的测试类型: {}", test_type),
        };

        // 记录结果
        let idx = counter.fetch_add(1, Ordering::SeqCst) as usize;
        match result {
            Ok(duration) => {
                latencies[idx].store(duration.as_nanos() as u64, Ordering::SeqCst);
            }
            Err(_) => {
                errors.fetch_add(1, Ordering::SeqCst);
            }
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {

    let config = BenchConfig::parse();

    println!("测试配置:");
    println!("  服务器地址: {}", config.server);
    println!("  客户端数量: {}", config.clients);
    println!("  每个客户端请求数: {}", config.requests);
    println!("  测试类型: {}", config.test_type);
    if config.test_type == "mixed" {
        println!("  写入/读取比例: {:.2}", config.write_ratio);
    }
    println!();

    // 计算总请求数
    let total_requests = config.clients * config.requests;
    let barrier = Arc::new(Barrier::new(config.clients + 1));
    let counter = Arc::new(AtomicU64::new(0));
    let latencies = Arc::new((0..total_requests).map(|_| AtomicU64::new(0)).collect::<Vec<_>>());
    let errors = Arc::new(AtomicU64::new(0));

    // 创建异步运行时
    let runtime = Builder::new_multi_thread().worker_threads(config.clients * 2).enable_all().build()?;

    // 开始测试
    let start_time = Instant::now();

    // 创建reqwest客户端
    let http_client = Client::builder().timeout(Duration::from_secs(10)).build()?;
    println!("开始测试...");
    // 启动客户端任务
    for client_id in 0..config.clients {
        let client = http_client.clone();
        let server = config.server.clone();
        let test_type = config.test_type.clone();
        let write_ratio = config.write_ratio;
        let barrier = barrier.clone();
        let counter = counter.clone();
        let latencies = latencies.clone();
        let errors = errors.clone();

        runtime.spawn(async move {
            client_task(
                client_id,
                client,
                server,
                config.requests,
                test_type,
                write_ratio,
                barrier,
                counter,
                latencies,
                errors,
            )
            .await;
        });
    }

    // 等待所有客户端准备就绪
    runtime.block_on(async { barrier.wait().await });

    // 等待所有任务完成
    while counter.load(Ordering::SeqCst) < total_requests as u64 {
        std::thread::sleep(Duration::from_millis(100));
    }
    
    let total_time = start_time.elapsed();

    // 收集结果
    let latencies_vec = latencies.iter().map(|a| Duration::from_nanos(a.load(Ordering::SeqCst))).collect::<Vec<_>>();

    let errors_count = errors.load(Ordering::SeqCst) as usize;

    // 打印结果
    let result = BenchResult::new(total_requests, total_time, &latencies_vec, errors_count);
    result.print();

    Ok(())
}
