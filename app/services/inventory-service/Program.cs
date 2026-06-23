using System.Text;
using System.Text.Json;
using Amazon.Runtime;
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

var sqsServiceUrl = builder.Configuration["AWS:ServiceUrl"];
var awsRegion = builder.Configuration["AWS:Region"] ?? "ap-south-1";
var priceSyncQueue = builder.Configuration["Queues:PriceSync"] ?? "appstack-price-sync";

builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(connStr).Build());

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

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "inventory" }));

app.MapGet("/inventory/bins", async (NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    return Results.Ok(await c.QueryAsync<Bin>("SELECT id, code, zone FROM bins ORDER BY code"));
}).RequireAuthorization();

// On-hand + recent movement history for one part.
app.MapGet("/inventory/{partId:guid}", async (Guid partId, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var head = await c.QuerySingleOrDefaultAsync<PartStock>(
        @"SELECT p.id AS PartId, p.part_number AS PartNumber, p.name, p.stock_qty AS OnHand
          FROM parts p WHERE p.id = @partId", new { partId });
    if (head is null) return Results.NotFound();

    var moves = await c.QueryAsync<Movement>(
        @"SELECT m.id, m.change, m.reason, b.code AS Bin, m.created_at AS CreatedAt
          FROM stock_movements m LEFT JOIN bins b ON b.id = m.bin_id
          WHERE m.part_id = @partId ORDER BY m.created_at DESC LIMIT 20", new { partId });

    return Results.Ok(new { head.PartId, head.PartNumber, head.Name, head.OnHand, movements = moves });
}).RequireAuthorization();

// Low-stock report for the demo dashboard.
app.MapGet("/inventory/low", async (NpgsqlDataSource db, int threshold = 20) =>
{
    await using var c = await db.OpenConnectionAsync();
    var rows = await c.QueryAsync(
        @"SELECT p.id, p.part_number AS ""partNumber"", p.name, p.stock_qty AS ""onHand""
          FROM parts p WHERE p.stock_qty < @threshold ORDER BY p.stock_qty ASC LIMIT 100",
        new { threshold });
    return Results.Ok(rows);
}).RequireAuthorization();

// Apply a stock movement (receive/issue). Updates the canonical parts.stock_qty,
// records the ledger row, then publishes price-sync so search reflects new stock.
app.MapPost("/inventory/movements", async (MovementReq req, NpgsqlDataSource db, PriceSyncPublisher pub) =>
{
    if (req.Change == 0) return Results.BadRequest(new { error = "change must be non-zero" });

    await using var c = await db.OpenConnectionAsync();
    await using var tx = await c.BeginTransactionAsync();

    int? binId = null;
    if (!string.IsNullOrWhiteSpace(req.BinCode))
    {
        binId = await c.ExecuteScalarAsync<int?>(
            "SELECT id FROM bins WHERE code = @code", new { code = req.BinCode }, tx);
        if (binId is null) return Results.BadRequest(new { error = $"unknown bin {req.BinCode}" });
    }

    // Apply only if it won't drive stock negative.
    var newQty = await c.ExecuteScalarAsync<int?>(
        @"UPDATE parts SET stock_qty = stock_qty + @change, updated_at = now()
          WHERE id = @partId AND stock_qty + @change >= 0
          RETURNING stock_qty",
        new { req.PartId, req.Change }, tx);

    if (newQty is null)
    {
        var exists = await c.ExecuteScalarAsync<bool>(
            "SELECT EXISTS(SELECT 1 FROM parts WHERE id = @partId)", new { req.PartId }, tx);
        return exists
            ? Results.Conflict(new { error = "insufficient stock for this issue" })
            : Results.NotFound();
    }

    await c.ExecuteAsync(
        @"INSERT INTO stock_movements(part_id, change, reason, bin_id)
          VALUES(@PartId, @Change, @Reason, @binId)",
        new { req.PartId, req.Change, Reason = req.Reason ?? "manual", binId }, tx);

    await tx.CommitAsync();
    await pub.PublishAsync(req.PartId, "upsert");

    return Results.Ok(new { partId = req.PartId, onHand = newQty });
}).RequireAuthorization();

app.Run();

record Bin(int Id, string Code, string Zone);
record PartStock(Guid PartId, string PartNumber, string Name, int OnHand);
record Movement(long Id, int Change, string Reason, string? Bin, DateTime CreatedAt);
record MovementReq(Guid PartId, int Change, string? Reason, string? BinCode);

// Same decoupled publisher as catalog-service: failures are logged, never block.
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
