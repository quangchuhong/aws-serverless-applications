#!/usr/bin/env python3
"""Bắn N request song song vào sync Lambda để quan sát concurrency & throttle.

Cách dùng:
    export API_URL="$(terraform output -raw sync_api_url)"
    python3 test_concurrency.py --requests 20 --concurrency 20

Lambda sleep 2s mỗi request. Với reserved_concurrency = 5:
  - 20 request song song -> ~5 request chạy cùng lúc
  - phần còn lại bị throttle (HTTP 500 kèm lỗi ở CloudWatch) hoặc phải chờ

Chỉ dùng thư viện chuẩn, không cần cài gì thêm.
"""

import argparse
import os
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor


def call(url, index):
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:
            return index, resp.status, time.perf_counter() - started, None
    except urllib.error.HTTPError as e:
        return index, e.code, time.perf_counter() - started, e.reason
    except Exception as e:  # noqa: BLE001 - muốn thấy mọi lỗi mạng
        return index, 0, time.perf_counter() - started, str(e)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default=os.environ.get("API_URL"))
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--concurrency", type=int, default=20)
    args = parser.parse_args()

    if not args.url:
        parser.error("Thiếu --url (hoặc biến môi trường API_URL)")

    print(f"Bắn {args.requests} request, {args.concurrency} luồng song song")
    print(f"Target: {args.url}\n")

    wall_start = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        results = list(pool.map(lambda i: call(args.url, i), range(args.requests)))
    wall = time.perf_counter() - wall_start

    statuses = Counter(status for _, status, _, _ in results)
    latencies = sorted(elapsed for _, _, elapsed, _ in results)

    for index, status, elapsed, err in sorted(results):
        suffix = f"  <- {err}" if err else ""
        print(f"  #{index:>3}  status={status:<4} {elapsed:6.2f}s{suffix}")

    print(f"\nTổng thời gian: {wall:.2f}s")
    print(f"Status: {dict(statuses)}")
    if latencies:
        p50 = latencies[len(latencies) // 2]
        p95 = latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))]
        print(f"Latency p50={p50:.2f}s  p95={p95:.2f}s  max={latencies[-1]:.2f}s")

    print(
        "\nĐối chiếu với CloudWatch → Metrics → Lambda → "
        "ConcurrentExecutions và Throttles để xem con số thực tế."
    )

    return 0 if statuses.get(200, 0) > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
