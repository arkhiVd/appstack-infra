using System.Text.Json;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.SQS;
using Amazon.SQS.Model;
using Dapper;
using Npgsql;
using Prometheus;

// =============================================================================
// pdf-ingest-worker
// Admin uploads a supplier catalog file to the S3 ingest bucket. S3 emits an
// ObjectCreated event to the pdf-ingest SQS queue. This worker:
//   1. reads the S3 event, downloads the object
//   2. parses rows (CSV: part_number,name,category,description,unit_price,uom,stock_qty)
//   3. upserts each part into Postgres (creating categories on demand)
//   4. publishes price-sync per part so search-sync-worker reindexes OpenSearch
// Same code runs as an ECS task in AWS; only endpoints change.
// =============================================================================

string Env(string key, string fallback) =>
    Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;

var connStr = Env("ConnectionStrings__Postgres",
    "Host=db;Port=5432;Database=appstack;Username=appstack;Password=appstack");
var serviceUrl = Env("AWS__ServiceUrl", "http://localstack:4566");
var awsRegion = Env("AWS__Region", "ap-south-1");
var pdfQueue = Env("Queues__PdfIngest", "appstack-pdf-ingest");
var priceSyncQueue = Env("Queues__PriceSync", "appstack-price-sync");

var jsonOpts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
var creds = new BasicAWSCredentials("test", "test");

await using var db = new NpgsqlDataSourceBuilder(connStr).Build();

var s3 = new AmazonS3Client(creds, new AmazonS3Config
{
    ServiceURL = serviceUrl,
    ForcePathStyle = true,                 // LocalStack needs path-style
    AuthenticationRegion = awsRegion,
});
var sqs = new AmazonSQSClient(creds, new AmazonSQSConfig
{
    ServiceURL = serviceUrl,
    AuthenticationRegion = awsRegion,
});

Log("starting");
new KestrelMetricServer(port: 9100).Start();   // expose /metrics for Prometheus
Log("metrics on :9100");
var pdfUrl = await ResolveQueueUrl(sqs, pdfQueue);
var priceUrl = await ResolveQueueUrl(sqs, priceSyncQueue);
Log($"consuming queue {pdfQueue}");

while (true)
{
    try
    {
        var resp = await sqs.ReceiveMessageAsync(new ReceiveMessageRequest
        {
            QueueUrl = pdfUrl,
            MaxNumberOfMessages = 10,
            WaitTimeSeconds = 20,
        });

        foreach (var msg in resp.Messages)
        {
            await HandleMessage(msg, db, s3, sqs, priceUrl, jsonOpts);
            await sqs.DeleteMessageAsync(pdfUrl, msg.ReceiptHandle);
        }
    }
    catch (Exception ex)
    {
        Log($"loop error: {ex.Message}");
        await Task.Delay(3000);
    }
}

// ----------------------------------------------------------------------------

static async Task HandleMessage(Message msg, NpgsqlDataSource db, IAmazonS3 s3,
    IAmazonSQS sqs, string priceUrl, JsonSerializerOptions opts)
{
    S3Event? evt;
    try { evt = JsonSerializer.Deserialize<S3Event>(msg.Body, opts); }
    catch { Log("non-S3 message ignored"); return; }
    if (evt?.Records is null || evt.Records.Count == 0) { Log("no records (test event?), ignored"); return; }

    foreach (var rec in evt.Records)
    {
        var bucket = rec.S3?.Bucket?.Name;
        var key = rec.S3?.Object?.Key;
        if (bucket is null || key is null) continue;
        key = Uri.UnescapeDataString(key.Replace('+', ' '));

        if (!key.EndsWith(".csv", StringComparison.OrdinalIgnoreCase))
        {
            Log($"skip {key}: only .csv supported in this worker");
            continue;
        }

        Log($"ingesting s3://{bucket}/{key}");
        var text = await Download(s3, bucket, key);
        var (ok, failed) = await ImportCsv(text, db, sqs, priceUrl);
        Log($"done {key}: upserted={ok} failed={failed}");
    }
}

static async Task<string> Download(IAmazonS3 s3, string bucket, string key)
{
    using var r = await s3.GetObjectAsync(bucket, key);
    using var sr = new StreamReader(r.ResponseStream);
    return await sr.ReadToEndAsync();
}

static async Task<(int ok, int failed)> ImportCsv(string text, NpgsqlDataSource db,
    IAmazonSQS sqs, string priceUrl)
{
    const string upsertSql = @"
        WITH cat AS (
            INSERT INTO categories(name, slug) VALUES (@cat, lower(@cat))
            ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
            RETURNING id
        )
        INSERT INTO parts(part_number, name, description, category_id, unit_price, uom, stock_qty)
        SELECT @pn, @name, @desc, (SELECT id FROM cat), @price, @uom, @qty
        ON CONFLICT (part_number) DO UPDATE SET
            name        = EXCLUDED.name,
            description = EXCLUDED.description,
            category_id = EXCLUDED.category_id,
            unit_price  = EXCLUDED.unit_price,
            uom         = EXCLUDED.uom,
            stock_qty   = EXCLUDED.stock_qty,
            updated_at  = now()
        RETURNING id";

    int ok = 0, failed = 0;
    var lines = text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
    await using var c = await db.OpenConnectionAsync();

    for (var i = 0; i < lines.Length; i++)
    {
        var cols = lines[i].Split(',');
        if (i == 0 && cols[0].Trim().Equals("part_number", StringComparison.OrdinalIgnoreCase))
            continue; // header
        if (cols.Length < 7) { failed++; continue; }

        try
        {
            var id = await c.ExecuteScalarAsync<Guid>(upsertSql, new
            {
                pn = cols[0].Trim(),
                name = cols[1].Trim(),
                cat = cols[2].Trim(),
                desc = cols[3].Trim(),
                price = decimal.Parse(cols[4].Trim(), System.Globalization.CultureInfo.InvariantCulture),
                uom = cols[5].Trim(),
                qty = int.Parse(cols[6].Trim()),
            });

            var body = JsonSerializer.Serialize(new { partId = id, op = "upsert" });
            await sqs.SendMessageAsync(new SendMessageRequest(priceUrl, body));
            ok++;
        }
        catch (Exception ex)
        {
            Log($"row {i} failed: {ex.Message}");
            failed++;
        }
    }
    return (ok, failed);
}

static async Task<string> ResolveQueueUrl(IAmazonSQS sqs, string name)
{
    for (var i = 0; i < 30; i++)
    {
        try { return (await sqs.GetQueueUrlAsync(name)).QueueUrl; }
        catch { await Task.Delay(2000); }
    }
    throw new InvalidOperationException($"queue {name} not found");
}

static void Log(string msg) => Console.WriteLine($"[pdf-ingest-worker] {msg}");

record S3Event(List<S3Record> Records);
record S3Record(S3Data S3);
record S3Data(S3Bucket Bucket, S3Object Object);
record S3Bucket(string Name);
record S3Object(string Key);
