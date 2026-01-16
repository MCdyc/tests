//! 多客户端RPC性能测试程序

use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::sync::Arc;
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
    fn new(
        total_requests: usize,
        total_time: Duration,
        latencies: &[Duration],
        errors: usize,
    ) -> Self {
        let mut latencies_sorted = latencies.to_vec();
        latencies_sorted.sort();

        let throughput = total_requests as f64 / total_time.as_secs_f64();
        let avg_latency = if total_requests > 0 {
            total_time / total_requests as u32
        } else {
            Duration::ZERO
        };

        let p50 = if !latencies_sorted.is_empty() {
            latencies_sorted[(latencies_sorted.len() * 50) / 100]
        } else {
            Duration::ZERO
        };
        let p95 = if !latencies_sorted.is_empty() {
            latencies_sorted[(latencies_sorted.len() * 95) / 100]
        } else {
            Duration::ZERO
        };
        let p99 = if !latencies_sorted.is_empty() {
            latencies_sorted[(latencies_sorted.len() * 99) / 100]
        } else {
            Duration::ZERO
        };

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
        println!("\n========================================");
        println!("性能测试结果:");
        println!("  总请求数: {}", self.total_requests);
        println!("  总耗时: {:?}", self.total_time);
        println!("  吞吐量: {:.2} req/s", self.throughput);
        println!("  平均延迟: {:?}", self.avg_latency);
        println!("  P50延迟: {:?}", self.p50_latency);
        println!("  P95延迟: {:?}", self.p95_latency);
        println!("  P99延迟: {:?}", self.p99_latency);
        println!("  错误数: {}", self.errors);
        println!("========================================\n");
    }
}

/// 执行单个写入请求
async fn perform_write(
    client: &Client,
    server: &str,
    key: &str,
    value: &str,
) -> Result<Duration, reqwest::Error> {
    let start = Instant::now();

    let payload = serde_json::json!({"Set": {"key": key, "value": value}});
    client
        .post(format!("{}/write", server))
        .json(&payload)
        .send()
        .await?;

    Ok(start.elapsed())
}

/// 执行单个读取请求
async fn perform_read(
    client: &Client,
    server: &str,
    key: &str,
) -> Result<Duration, reqwest::Error> {
    let start = Instant::now();

    client
        .post(format!("{}/read", server))
        .json(key)
        .send()
        .await?;

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
                if idx < latencies.len() {
                    latencies[idx].store(duration.as_nanos() as u64, Ordering::SeqCst);
                }
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

    let total_requests = config.clients * config.requests;
    let barrier = Arc::new(Barrier::new(config.clients + 1));
    let counter = Arc::new(AtomicU64::new(0));
    let latencies = Arc::new(
        (0..total_requests)
            .map(|_| AtomicU64::new(0))
            .collect::<Vec<_>>(),
    );
    let errors = Arc::new(AtomicU64::new(0));

    let runtime = Builder::new_multi_thread()
        .worker_threads(config.clients * 2)
        .enable_all()
        .build()?;

    let http_client = Client::builder()
        .timeout(Duration::from_secs(10))
        .pool_max_idle_per_host(config.clients)
        .build()?;

    println!("正在准备任务...");
    let start_time = Instant::now();

    for client_id in 0..config.clients {
        let client = http_client.clone();
        let server = config.server.clone();
        let test_type = config.test_type.clone();
        let write_ratio = config.write_ratio;
        let barrier = barrier.clone();
        let counter = counter.clone();
        let latencies = latencies.clone();
        let errors = errors.clone();
        let requests_per_client = config.requests; // 修复点：明确提取变量

        runtime.spawn(async move {
            client_task(
                client_id,
                client,
                server,
                requests_per_client, // 使用修复后的变量
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

    // 所有线程到达同步点，开始测试
    println!("开始测试...");
    runtime.block_on(async { barrier.wait().await });

    let mut last_print_time = Instant::now();
    let mut last_count = 0;

    // 主循环：每5秒输出进度
    loop {
        let current_count = counter.load(Ordering::SeqCst);

        if current_count >= total_requests as u64 {
            break;
        }

        if last_print_time.elapsed() >= Duration::from_secs(5) {
            let now = Instant::now();
            let elapsed = now.duration_since(last_print_time).as_secs_f64();
            let delta = current_count - last_count;
            let tps = delta as f64 / elapsed;
            let percentage = (current_count as f64 / total_requests as f64) * 100.0;

            println!(
                "[{:?}] 进度: {} / {} ({:.2}%) | 近5秒平均速度: {:.2} req/s",
                start_time.elapsed(),
                current_count,
                total_requests,
                percentage,
                tps
            );

            last_print_time = now;
            last_count = current_count;
        }

        std::thread::sleep(Duration::from_millis(200));
    }

    let total_time = start_time.elapsed();

    // 收集非零延迟数据
    let latencies_vec: Vec<Duration> = latencies
        .iter()
        .map(|a| Duration::from_nanos(a.load(Ordering::SeqCst)))
        .filter(|d| !d.is_zero())
        .collect();

    let errors_count = errors.load(Ordering::SeqCst) as usize;

    let result = BenchResult::new(total_requests, total_time, &latencies_vec, errors_count);
    result.print();

    Ok(())
}
