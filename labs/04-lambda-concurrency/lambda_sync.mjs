// Lambda A – invoke đồng bộ qua API Gateway HTTP API.
// Sleep 2s để mô phỏng xử lý lâu, giúp quan sát concurrency khi bắn tải song song.

const SLEEP_MS = 2000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export const handler = async (event) => {
  console.log("EVENT:", JSON.stringify(event));

  const start = Date.now();
  await sleep(SLEEP_MS);

  return {
    statusCode: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      message: "ok",
      // requestId khác nhau ở mỗi request; logStreamName giống nhau nghĩa là
      // cùng một execution environment (instance) xử lý — dấu hiệu của reuse.
      requestId: event.requestContext?.requestId,
      logStream: process.env.AWS_LAMBDA_LOG_STREAM_NAME,
      elapsedMs: Date.now() - start,
    }),
  };
};
