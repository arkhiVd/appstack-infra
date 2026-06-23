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

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "orders" }));

// Raise a requisition (any authenticated user).
app.MapPost("/orders/requisitions", async (CreateReqReq req, NpgsqlDataSource db, HttpContext ctx) =>
{
    if (req.Lines is null || req.Lines.Count == 0)
        return Results.BadRequest(new { error = "at least one line required" });
    if (req.Lines.Any(l => l.Qty <= 0))
        return Results.BadRequest(new { error = "qty must be > 0" });

    var requestedBy = req.RequestedBy
        ?? ctx.User.FindFirst(System.Security.Claims.ClaimTypes.Email)?.Value
        ?? "staff";

    await using var c = await db.OpenConnectionAsync();
    await using var tx = await c.BeginTransactionAsync();
    try
    {
        var id = await c.ExecuteScalarAsync<Guid>(
            "INSERT INTO requisitions(requested_by) VALUES(@requestedBy) RETURNING id",
            new { requestedBy }, tx);

        foreach (var l in req.Lines)
            await c.ExecuteAsync(
                "INSERT INTO requisition_items(requisition_id, part_id, qty) VALUES(@id, @PartId, @Qty)",
                new { id, l.PartId, l.Qty }, tx);

        await tx.CommitAsync();
        return Results.Created($"/orders/requisitions/{id}", new { id, status = "pending" });
    }
    catch (PostgresException ex) when (ex.SqlState == "23503")
    {
        return Results.BadRequest(new { error = "one or more part_id values do not exist" });
    }
}).RequireAuthorization();

// List requisitions (optionally by status).
app.MapGet("/orders/requisitions", async (NpgsqlDataSource db, string? status) =>
{
    await using var c = await db.OpenConnectionAsync();
    var rows = await c.QueryAsync(
        @"SELECT r.id, r.requested_by AS ""requestedBy"", r.status, r.created_at AS ""createdAt"",
                 r.decided_at AS ""decidedAt"", count(i.id) AS lines
          FROM requisitions r LEFT JOIN requisition_items i ON i.requisition_id = r.id
          WHERE (@status IS NULL OR r.status = @status)
          GROUP BY r.id ORDER BY r.created_at DESC LIMIT 100",
        new { status });
    return Results.Ok(rows);
}).RequireAuthorization();

// Requisition detail with line parts.
app.MapGet("/orders/requisitions/{id:guid}", async (Guid id, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var head = await c.QuerySingleOrDefaultAsync(
        @"SELECT id, requested_by AS ""requestedBy"", status, created_at AS ""createdAt"", decided_at AS ""decidedAt""
          FROM requisitions WHERE id = @id", new { id });
    if (head is null) return Results.NotFound();

    var lines = await c.QueryAsync(
        @"SELECT i.part_id AS ""partId"", p.part_number AS ""partNumber"", p.name, i.qty
          FROM requisition_items i JOIN parts p ON p.id = i.part_id
          WHERE i.requisition_id = @id ORDER BY p.part_number", new { id });
    return Results.Ok(new { head, lines });
}).RequireAuthorization();

// Approve (admin): atomically deduct stock for every line, or fail whole thing.
app.MapPut("/orders/requisitions/{id:guid}/approve", async (Guid id, NpgsqlDataSource db, PriceSyncPublisher pub) =>
{
    await using var c = await db.OpenConnectionAsync();
    await using var tx = await c.BeginTransactionAsync();

    var status = await c.ExecuteScalarAsync<string?>(
        "SELECT status FROM requisitions WHERE id = @id FOR UPDATE", new { id }, tx);
    if (status is null) return Results.NotFound();
    if (status != "pending") return Results.Conflict(new { error = $"already {status}" });

    var items = (await c.QueryAsync<(Guid PartId, int Qty)>(
        "SELECT part_id AS PartId, qty AS Qty FROM requisition_items WHERE requisition_id = @id",
        new { id }, tx)).ToList();

    var affected = new List<object>();
    foreach (var it in items)
    {
        var newQty = await c.ExecuteScalarAsync<int?>(
            @"UPDATE parts SET stock_qty = stock_qty - @Qty, updated_at = now()
              WHERE id = @PartId AND stock_qty >= @Qty
              RETURNING stock_qty",
            new { it.PartId, it.Qty }, tx);

        if (newQty is null)
            // insufficient stock -> tx disposes without commit (rolls back)
            return Results.Conflict(new { error = "insufficient stock", partId = it.PartId, qty = it.Qty });

        await c.ExecuteAsync(
            @"INSERT INTO stock_movements(part_id, change, reason)
              VALUES(@PartId, @neg, @reason)",
            new { it.PartId, neg = -it.Qty, reason = $"requisition {id}" }, tx);

        affected.Add(new { partId = it.PartId, qty = it.Qty, onHand = newQty });
    }

    await c.ExecuteAsync(
        "UPDATE requisitions SET status = 'approved', decided_at = now() WHERE id = @id",
        new { id }, tx);
    await tx.CommitAsync();

    foreach (var it in items) await pub.PublishAsync(it.PartId, "upsert");

    return Results.Ok(new { id, status = "approved", lines = affected });
}).RequireAuthorization(p => p.RequireRole("admin"));

// Reject (admin).
app.MapPut("/orders/requisitions/{id:guid}/reject", async (Guid id, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var n = await c.ExecuteAsync(
        "UPDATE requisitions SET status = 'rejected', decided_at = now() WHERE id = @id AND status = 'pending'",
        new { id });
    return n == 0 ? Results.Conflict(new { error = "not found or not pending" }) : Results.Ok(new { id, status = "rejected" });
}).RequireAuthorization(p => p.RequireRole("admin"));

app.Run();

record LineReq(Guid PartId, int Qty);
record CreateReqReq(string? RequestedBy, List<LineReq> Lines);

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
