//! 无图形环境的逐局回放校验入口.

use balatro_engine::data::json::Json;
use balatro_engine::replay;
use std::path::Path;

fn run(path: &Path, strict: bool) -> Result<bool, String> {
    let text = std::fs::read_to_string(path).map_err(|error| error.to_string())?;
    let (header, steps) = if path.extension().is_some_and(|extension| extension == "jsonl") {
        let mut lines = text.lines().filter(|line| !line.trim().is_empty());
        let header = Json::parse(lines.next().ok_or("fixture 缺头部")?).map_err(|e| e.to_string())?;
        let steps = lines.map(Json::parse).collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
        (header, steps)
    } else {
        let parsed = Json::parse(&text).map_err(|e| e.to_string())?;
        let run = parsed.get("run").ok_or("回放缺开局参数")?;
        if run.get("resumed").and_then(Json::as_bool) == Some(true)
            || run.get("tutorial").and_then(Json::as_bool) == Some(true) {
            return Err("读档局与教程局不在规则引擎范围内".to_owned());
        }
        let mut header = Vec::new();
        for key in ["seed", "deck", "stake"] {
            header.push((key.to_owned(), run.get(key).cloned().ok_or_else(|| format!("回放缺 {key}"))?));
        }
        header.push(("uda".to_owned(), parsed.get("snapshot").and_then(|v| v.get("uda"))
            .cloned().ok_or("回放缺解锁快照")?));
        let steps = parsed.get("actions").and_then(Json::as_array).ok_or("回放缺动作")?.to_vec();
        (Json::Object(header), steps)
    };
    let report = replay::check(&header, &steps, strict);
    let seed = header.get("seed").and_then(Json::as_str).unwrap_or("?");
    let result = if report.failure.is_some() { "FAIL" } else { "PASS" };
    println!("{result}\t{seed}\tdigests={} refusals={} unverified={} observations={}\t{}",
        report.matched_digests, report.matched_refusals, report.unverified_actions,
        report.skipped_observations, path.display());
    if let Some(failure) = report.failure { println!("  {failure}"); }
    if let Some(expected) = report.expected { println!("  GAME {expected}"); }
    if let Some(actual) = report.actual { println!("  ENGINE {actual}"); }
    Ok(result == "PASS")
}

fn main() {
    let mut strict = false;
    let mut paths = Vec::new();
    for argument in std::env::args().skip(1) {
        match argument.as_str() {
            "--strict" => strict = true,
            "-h" | "--help" => {
                println!("replay_check [--strict] <回放.json | fixture.jsonl> ...");
                return;
            },
            _ => paths.push(argument),
        }
    }
    if paths.is_empty() {
        eprintln!("需要至少一份回放文件, 使用 --help 查看用法");
        std::process::exit(2);
    }
    let started = std::time::Instant::now();
    let mut failed = 0;
    for path in &paths {
        match run(Path::new(path), strict) {
            Ok(true) => {},
            Ok(false) => failed += 1,
            Err(error) => { failed += 1; eprintln!("ERROR\t{path}\t{error}"); },
        }
    }
    println!("校验完成: {}/{} 局无摘要分歧, 耗时 {:.3}s", paths.len() - failed, paths.len(), started.elapsed().as_secs_f64());
    if failed > 0 { std::process::exit(1); }
}
