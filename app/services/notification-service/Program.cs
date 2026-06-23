using System.Text;
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
var threshold = builder.Configuration.GetValue<int?>("Notify:LowStockThreshold") ?? 10;
var intervalSec = builder.Configuration.GetValue<int?>("Notify:IntervalSeconds") ?? 15;

builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(connStr).Build());
builder.Services.AddHostedService(sp => new LowStockMonitor(
    sp.GetRequiredService<NpgsqlDataSource>(),
    sp.GetRequiredService<ILogger<LowStockMonitor>>(),
    threshold, intervalSec));

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

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "notification" }));

app.MapGet("/notifications", async (NpgsqlDataSource db, string? kind, int limit = 50) =>
{
    limit = Math.Clamp(limit, 1, 200);
    await using var c = await db.OpenConnectionAsync();
    var rows = await c.QueryAsync(
        @"SELECT id, kind, part_id AS ""partId"", message, created_at AS ""createdAt""
          FROM notifications
          WHERE (@kind IS NULL OR kind = @kind)
          ORDER BY created_at DESC LIMIT @limit",
        new { kind, limit });
    return Results.Ok(rows);
}).RequireAuthorization();

app.Run();

// Background monitor: periodically scans for parts below the low-stock threshold
// and records a 'low_stock' notification (deduped within a 30-min window). The
// log line stands in for a real email/Slack fan-out.
public class LowStockMonitor(NpgsqlDataSource db, ILogger<LowStockMonitor> log, int threshold, int intervalSec)
    : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
        log.LogInformation("low-stock monitor started (threshold={Threshold}, interval={Interval}s)", threshold, intervalSec);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using var c = await db.OpenConnectionAsync(stoppingToken);
                var raised = (await c.QueryAsync<Guid>(
                    @"WITH low AS (
                          SELECT p.id, p.part_number, p.stock_qty
                          FROM parts p
                          WHERE p.stock_qty < @threshold
                            AND NOT EXISTS (
                                SELECT 1 FROM notifications n
                                WHERE n.part_id = p.id AND n.kind = 'low_stock'
                                  AND n.created_at > now() - interval '30 minutes')
                      )
                      INSERT INTO notifications(kind, part_id, message)
                      SELECT 'low_stock', id,
                             'Low stock: ' || part_number || ' at ' || stock_qty || ' (< ' || @threshold || ')'
                      FROM low
                      RETURNING part_id",
                    new { threshold })).Count();

                if (raised > 0) log.LogWarning("raised {Count} low-stock alert(s) [would email/slack]", raised);
            }
            catch (Exception ex)
            {
                log.LogError("monitor error: {Error}", ex.Message);
            }

            await Task.Delay(TimeSpan.FromSeconds(intervalSec), stoppingToken);
        }
    }
}
