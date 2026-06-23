using System.Text.Json;
using Amazon.Runtime;
using Amazon.SQS;
using Amazon.SQS.Model;
using Dapper;
using Npgsql;
using OpenSearch.Client;
using Prometheus;

// =============================================================================
// search-sync-worker
// Consumes the price-sync SQS queue. Each message = { partId, op }.
//   upsert -> read the part from Postgres, index it into OpenSearch
//   delete -> remove the document from OpenSearch
// On startup: ensure the index exists and bulk-load all parts if it is empty.
// In AWS this same code runs as an ECS task; only the endpoints change.
// =============================================================================

string Env(string key, string fallback) =>
    Environment.GetEnvironmentVariable(key) is { Length: > 0 } v ? v : fallback;

var connStr = Env("ConnectionStrings__Postgres",
    "Host=db;Port=5432;Database=appstack;Username=appstack;Password=appstack");
var sqsServiceUrl = Env("AWS__ServiceUrl", "http://localstack:4566");
var awsRegion = Env("AWS__Region", "ap-south-1");
var queueName = Env("Queues__PriceSync", "appstack-price-sync");
var osUrl = Env("OpenSearch__Url", "http://opensearch:9200");
var indexName = Env("OpenSearch__Index", "parts");

const string PartSelect = @"
    SELECT p.id AS Id, p.part_number AS PartNumber, p.name AS Name, p.description AS Description,
           c.name AS Category, p.unit_price AS UnitPrice, p.uom AS Uom, p.stock_qty AS StockQty
    FROM parts p JOIN categories c ON c.id = p.category_id";

var jsonOpts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };

await using var db = new NpgsqlDataSourceBuilder(connStr).Build();

var osSettings = new ConnectionSettings(new Uri(osUrl)).DefaultIndex(indexName);
var os = new OpenSearchClient(osSettings);

var sqsConfig = new AmazonSQSConfig { ServiceURL = sqsServiceUrl, AuthenticationRegion = awsRegion };
var sqs = new AmazonSQSClient(new BasicAWSCredentials("test", "test"), sqsConfig);

Log("starting");
new KestrelMetricServer(port: 9100).Start();   // expose /metrics for Prometheus
Log("metrics on :9100");

await WaitForOpenSearch(os);
await EnsureIndex(os, indexName);
await BackfillIfEmpty(os, db, indexName);

var queueUrl = await ResolveQueueUrl(sqs, queueName);
Log($"consuming queue {queueName}");

while (true)
{
    try
    {
        var resp = await sqs.ReceiveMessageAsync(new ReceiveMessageRequest
        {
            QueueUrl = queueUrl,
            MaxNumberOfMessages = 10,
            WaitTimeSeconds = 20, // long poll
        });

        foreach (var msg in resp.Messages)
        {
            await Handle(msg, db, os, indexName, jsonOpts);
            await sqs.DeleteMessageAsync(queueUrl, msg.ReceiptHandle);
        }
    }
    catch (Exception ex)
    {
        Log($"loop error: {ex.Message}");
        await Task.Delay(3000);
    }
}

// ----------------------------------------------------------------------------

static async Task Handle(Message msg, NpgsqlDataSource db, OpenSearchClient os,
    string index, JsonSerializerOptions opts)
{
    SyncMsg? m;
    try { m = JsonSerializer.Deserialize<SyncMsg>(msg.Body, opts); }
    catch { Log($"bad message dropped: {msg.Body}"); return; }
    if (m is null || m.PartId == Guid.Empty) { Log($"empty message dropped"); return; }

    if (m.Op == "delete")
    {
        await os.DeleteAsync<PartDoc>(m.PartId, d => d.Index(index));
        Log($"deleted {m.PartId}");
        return;
    }

    // upsert
    await using var c = await db.OpenConnectionAsync();
    var doc = await c.QuerySingleOrDefaultAsync<PartDoc>(PartSelect + " WHERE p.id=@id", new { id = m.PartId });
    if (doc is null) { Log($"part {m.PartId} not found, skip"); return; }

    var r = await os.IndexAsync(doc, i => i.Index(index).Id(doc.Id));
    if (!r.IsValid) Log($"index failed {doc.Id}: {r.DebugInformation}");
    else Log($"indexed {doc.PartNumber}");
}

static async Task EnsureIndex(OpenSearchClient os, string index)
{
    var exists = await os.Indices.ExistsAsync(index);
    if (exists.Exists) return;

    var create = await os.Indices.CreateAsync(index, c => c
        .Map<PartDoc>(m => m.Properties(p => p
            .Keyword(k => k.Name(x => x.Id))
            .Text(t => t.Name(x => x.PartNumber))
            .Text(t => t.Name(x => x.Name))
            .Text(t => t.Name(x => x.Description))
            .Keyword(k => k.Name(x => x.Category))
            .Number(n => n.Name(x => x.UnitPrice).Type(NumberType.Double))
            .Keyword(k => k.Name(x => x.Uom))
            .Number(n => n.Name(x => x.StockQty).Type(NumberType.Integer)))));

    Log(create.IsValid ? $"created index {index}" : $"create index failed: {create.DebugInformation}");
}

static async Task BackfillIfEmpty(OpenSearchClient os, NpgsqlDataSource db, string index)
{
    var count = await os.CountAsync<PartDoc>(c => c.Index(index));
    if (count.IsValid && count.Count > 0) { Log($"index has {count.Count} docs, skip backfill"); return; }

    await using var c = await db.OpenConnectionAsync();
    var all = (await c.QueryAsync<PartDoc>(PartSelect)).ToList();
    if (all.Count == 0) { Log("no parts to backfill"); return; }

    var bulk = await os.BulkAsync(b => b.Index(index).IndexMany(all, (d, doc) => d.Id(doc.Id)));
    Log(bulk.Errors ? $"backfill had errors: {bulk.DebugInformation}" : $"backfilled {all.Count} parts");
    await os.Indices.RefreshAsync(index);
}

static async Task WaitForOpenSearch(OpenSearchClient os)
{
    for (var i = 0; i < 30; i++)
    {
        var ping = await os.PingAsync();
        if (ping.IsValid) { Log("opensearch reachable"); return; }
        await Task.Delay(2000);
    }
    Log("opensearch not reachable after retries, continuing anyway");
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

static void Log(string msg) => Console.WriteLine($"[search-sync-worker] {msg}");

record SyncMsg(Guid PartId, string Op);

public class PartDoc
{
    public Guid Id { get; set; }
    public string PartNumber { get; set; } = default!;
    public string Name { get; set; } = default!;
    public string? Description { get; set; }
    public string Category { get; set; } = default!;
    public decimal UnitPrice { get; set; }
    public string Uom { get; set; } = default!;
    public int StockQty { get; set; }
}
