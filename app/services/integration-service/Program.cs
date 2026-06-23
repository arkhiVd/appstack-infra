using System.Text;
using System.Text.Json;
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
// Shared secret an external system must present. Stub auth for inbound webhooks.
var webhookToken = builder.Configuration["Integration:WebhookToken"] ?? "dev-webhook-token";

builder.Services.AddSingleton(_ => new NpgsqlDataSourceBuilder(connStr).Build());
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

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "integration" }));

// Inbound webhook from an external system (e.g. ERP). Authenticated by a static
// token header, stored, acknowledged. Downstream processing is out of scope.
app.MapPost("/integration/webhooks/inbound", async (HttpRequest http, NpgsqlDataSource db) =>
{
    if (http.Headers["X-Webhook-Token"] != webhookToken)
        return Results.Json(new { error = "invalid webhook token" }, statusCode: 401);

    using var reader = new StreamReader(http.Body);
    var raw = await reader.ReadToEndAsync();
    if (string.IsNullOrWhiteSpace(raw)) return Results.BadRequest(new { error = "empty body" });

    string source = "unknown", eventType = "unknown";
    try
    {
        using var doc = JsonDocument.Parse(raw);
        if (doc.RootElement.TryGetProperty("source", out var s)) source = s.GetString() ?? source;
        if (doc.RootElement.TryGetProperty("eventType", out var e)) eventType = e.GetString() ?? eventType;
    }
    catch (JsonException)
    {
        return Results.BadRequest(new { error = "body must be valid JSON" });
    }

    await using var c = await db.OpenConnectionAsync();
    var id = await c.ExecuteScalarAsync<long>(
        @"INSERT INTO integration_events(source, event_type, payload)
          VALUES(@source, @eventType, @raw::jsonb) RETURNING id",
        new { source, eventType, raw });

    return Results.Accepted($"/integration/events/{id}", new { id, status = "accepted" });
});

app.MapGet("/integration/events", async (NpgsqlDataSource db, int limit = 50) =>
{
    limit = Math.Clamp(limit, 1, 200);
    await using var c = await db.OpenConnectionAsync();
    var rows = await c.QueryAsync(
        @"SELECT id, source, event_type AS ""eventType"", payload::text AS payload,
                 received_at AS ""receivedAt""
          FROM integration_events ORDER BY received_at DESC LIMIT @limit", new { limit });
    return Results.Ok(rows);
}).RequireAuthorization();

app.Run();
