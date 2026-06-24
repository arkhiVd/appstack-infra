using System.Text;
using System.Text.Json;
using Amazon;
using Amazon.Runtime;
using Amazon.S3;
using Amazon.S3.Model;
using Amazon.SQS;
using Amazon.SQS.Model;
using Dapper;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Npgsql;
using Prometheus;

var builder = WebApplication.CreateBuilder(args);

var connStr = builder.Configuration.GetConnectionString("Postgres")
    ?? "Host=db;Port=5432;Database=appstack;Username=appstack;Password=appstack";
var jwtKey = builder.Configuration["Jwt:Key"] ?? "dev-only-secret-please-override-32bytes-min!";
var jwtIssuer = builder.Configuration["Jwt:Issuer"] ?? "appstack";

var sqsServiceUrl = builder.Configuration["AWS:ServiceUrl"]; // null in AWS -> default endpoint
var awsRegion = builder.Configuration["AWS:Region"] ?? "ap-south-1";
var priceSyncQueue = builder.Configuration["Queues:PriceSync"] ?? "appstack-price-sync";
var pdfBucket = builder.Configuration["Storage:PdfBucket"] ?? "appstack-pdf-ingest";

builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(connStr).Build());

// S3 client for server-side bulk-import upload (browser -> API -> S3 ingest
// bucket). Local uses LocalStack (path-style + dummy creds); AWS uses the real
// regional endpoint + task-role creds.
builder.Services.AddSingleton<IAmazonS3>(_ =>
    string.IsNullOrEmpty(sqsServiceUrl)
        ? new AmazonS3Client(new AmazonS3Config { RegionEndpoint = RegionEndpoint.GetBySystemName(awsRegion) })
        : new AmazonS3Client(new BasicAWSCredentials("test", "test"),
            new AmazonS3Config { ServiceURL = sqsServiceUrl, ForcePathStyle = true, AuthenticationRegion = awsRegion }));

// SQS publisher — fires a price-sync event after every catalog write so the
// search-sync-worker can update OpenSearch. Decoupled: a publish failure is
// logged, never blocks the DB write (DB is source of truth).
builder.Services.AddSingleton<IAmazonSQS>(_ =>
{
    var cfg = new AmazonSQSConfig { AuthenticationRegion = awsRegion };
    if (!string.IsNullOrEmpty(sqsServiceUrl)) cfg.ServiceURL = sqsServiceUrl;
    return string.IsNullOrEmpty(sqsServiceUrl)
        ? new AmazonSQSClient(cfg)
        : new AmazonSQSClient(new BasicAWSCredentials("test", "test"), cfg);
});
builder.Services.AddSingleton(sp =>
    new PriceSyncPublisher(sp.GetRequiredService<IAmazonSQS>(), priceSyncQueue,
        sp.GetRequiredService<ILoggerFactory>().CreateLogger("PriceSyncPublisher")));
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(o =>
    {
        o.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = jwtIssuer,
            ValidateAudience = true,
            ValidAudience = jwtIssuer,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey)),
            ValidateLifetime = true,
        };
    });
builder.Services.AddAuthorization();

var app = builder.Build();
app.UseSwagger();
app.UseSwaggerUI();
app.UseHttpMetrics();
app.UseAuthentication();
app.UseAuthorization();

app.MapMetrics();

const string PartSelect = @"
    SELECT p.id, p.part_number AS PartNumber, p.name, p.description,
           c.name AS Category, p.unit_price AS UnitPrice, p.uom, p.stock_qty AS StockQty
    FROM parts p JOIN categories c ON c.id = p.category_id";

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "catalog" }));

// ---- Categories ------------------------------------------------------------
app.MapGet("/catalog/categories", async (NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var rows = await c.QueryAsync<Category>("SELECT id, name, slug FROM categories ORDER BY name");
    return Results.Ok(rows);
}).RequireAuthorization();

// ---- Parts: list (paged, optional q + category filter) ---------------------
app.MapGet("/catalog/parts", async (NpgsqlDataSource db, string? q, int? categoryId,
    int page = 1, int pageSize = 20) =>
{
    pageSize = Math.Clamp(pageSize, 1, 100);
    page = Math.Max(page, 1);
    await using var c = await db.OpenConnectionAsync();
    var rows = await c.QueryAsync<PartDto>(PartSelect + @"
        WHERE (@q IS NULL OR p.name ILIKE '%'||@q||'%' OR p.part_number ILIKE '%'||@q||'%')
          AND (@cat IS NULL OR p.category_id = @cat)
        ORDER BY p.part_number
        LIMIT @lim OFFSET @off",
        new { q, cat = categoryId, lim = pageSize, off = (page - 1) * pageSize });
    return Results.Ok(rows);
}).RequireAuthorization();

// ---- Parts: get one --------------------------------------------------------
app.MapGet("/catalog/parts/{id:guid}", async (Guid id, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var p = await c.QuerySingleOrDefaultAsync<PartDto>(PartSelect + " WHERE p.id=@id", new { id });
    return p is null ? Results.NotFound() : Results.Ok(p);
}).RequireAuthorization();

// ---- Parts: create (admin) -------------------------------------------------
app.MapPost("/catalog/parts", async (CreatePartReq req, NpgsqlDataSource db, PriceSyncPublisher pub) =>
{
    await using var c = await db.OpenConnectionAsync();
    try
    {
        var id = await c.ExecuteScalarAsync<Guid>(@"
            INSERT INTO parts(part_number,name,description,category_id,unit_price,uom,stock_qty)
            VALUES(@PartNumber,@Name,@Description,@CategoryId,@UnitPrice,@Uom,@StockQty)
            RETURNING id", req);
        await pub.PublishAsync(id, "upsert");
        return Results.Created($"/catalog/parts/{id}", new { id });
    }
    catch (PostgresException ex) when (ex.SqlState == "23505")
    {
        return Results.Conflict(new { error = "part_number already exists" });
    }
    catch (PostgresException ex) when (ex.SqlState == "23503")
    {
        return Results.BadRequest(new { error = "category_id does not exist" });
    }
}).RequireAuthorization(p => p.RequireRole("admin"));

// ---- Parts: update (admin) -------------------------------------------------
app.MapPut("/catalog/parts/{id:guid}", async (Guid id, UpdatePartReq req, NpgsqlDataSource db, PriceSyncPublisher pub) =>
{
    await using var c = await db.OpenConnectionAsync();
    var n = await c.ExecuteAsync(@"
        UPDATE parts SET name=@Name, description=@Description, unit_price=@UnitPrice,
               uom=@Uom, stock_qty=@StockQty, updated_at=now() WHERE id=@id",
        new { id, req.Name, req.Description, req.UnitPrice, req.Uom, req.StockQty });
    if (n > 0) await pub.PublishAsync(id, "upsert");
    return n == 0 ? Results.NotFound() : Results.NoContent();
}).RequireAuthorization(p => p.RequireRole("admin"));

// ---- Parts: delete (admin) -------------------------------------------------
app.MapDelete("/catalog/parts/{id:guid}", async (Guid id, NpgsqlDataSource db, PriceSyncPublisher pub) =>
{
    await using var c = await db.OpenConnectionAsync();
    var n = await c.ExecuteAsync("DELETE FROM parts WHERE id=@id", new { id });
    if (n > 0) await pub.PublishAsync(id, "delete");
    return n == 0 ? Results.NotFound() : Results.NoContent();
}).RequireAuthorization(p => p.RequireRole("admin"));

// Bulk import: admin uploads a CSV through the API; we write it to the S3 ingest
// bucket server-side, which fires the ObjectCreated -> pdf-ingest pipeline. Going
// through the API keeps it same-origin (no browser->S3 CORS, no presigned URLs).
app.MapPost("/catalog/import", async (IFormFile file, IAmazonS3 s3) =>
{
    if (file is null || file.Length == 0) return Results.BadRequest(new { error = "empty file" });
    var key = $"upload-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}-{Guid.NewGuid():N}.csv";
    await using var stream = file.OpenReadStream();
    await s3.PutObjectAsync(new PutObjectRequest
    {
        BucketName  = pdfBucket,
        Key         = key,
        InputStream = stream,
        ContentType = "text/csv",
    });
    return Results.Accepted($"s3://{pdfBucket}/{key}", new { key });
}).RequireAuthorization(p => p.RequireRole("admin")).DisableAntiforgery();

app.Run();

// Publishes { partId, op } to the price-sync SQS queue. Resolves the queue URL
// once and caches it. Failures are swallowed (logged) so the API write succeeds
// even if messaging is down — the worker reconciles on the next event/backfill.
public class PriceSyncPublisher
{
    private readonly IAmazonSQS _sqs;
    private readonly string _queueName;
    private readonly ILogger _log;
    private string? _url;

    public PriceSyncPublisher(IAmazonSQS sqs, string queueName, ILogger log)
    {
        _sqs = sqs;
        _queueName = queueName;
        _log = log;
    }

    public async Task PublishAsync(Guid partId, string op)
    {
        try
        {
            _url ??= (await _sqs.GetQueueUrlAsync(_queueName)).QueueUrl;
            var body = JsonSerializer.Serialize(new { partId, op });
            await _sqs.SendMessageAsync(new SendMessageRequest(_url, body));
        }
        catch (Exception ex)
        {
            _log.LogWarning("price-sync publish failed for {PartId}/{Op}: {Error}", partId, op, ex.Message);
        }
    }
}

record Category(int Id, string Name, string Slug);
record PartDto(Guid Id, string PartNumber, string Name, string? Description,
    string Category, decimal UnitPrice, string Uom, int StockQty);
record CreatePartReq(string PartNumber, string Name, string? Description,
    int CategoryId, decimal UnitPrice, string Uom, int StockQty);
record UpdatePartReq(string Name, string? Description, decimal UnitPrice, string Uom, int StockQty);
