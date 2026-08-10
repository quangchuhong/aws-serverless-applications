// Lambda B – invoke bất đồng bộ từ S3 ObjectCreated.
//
// Đặt biến môi trường SIMULATE_FAILURE=true để handler luôn throw, dùng để
// quan sát: retry 2 lần -> event đi vào on_failure destination (SQS).

export const handler = async (event) => {
  console.log("S3 Event:", JSON.stringify(event));

  for (const record of event.Records ?? []) {
    const bucket = record.s3.bucket.name;
    const key = decodeURIComponent(record.s3.object.key.replace(/\+/g, " "));

    console.log(`Processing s3://${bucket}/${key}`);

    if (process.env.SIMULATE_FAILURE === "true") {
      throw new Error("Simulated processing error");
    }
  }

  return { status: "ok" };
};
