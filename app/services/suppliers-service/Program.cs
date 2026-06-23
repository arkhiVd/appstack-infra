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
app.UseHttpMetrics();          // record per-request Prometheus metrics
app.UseAuthentication();
app.UseAuthorization();

app.MapMetrics();              // expose /metrics for Prometheus scrape

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "suppliers" }));

app.MapGet("/suppliers", async (NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    return Results.Ok(await c.QueryAsync<Supplier>(
        @"SELECT id, code, name, contact_email AS ContactEmail, phone,
                 lead_time_days AS LeadTimeDays FROM suppliers ORDER BY code"));
}).RequireAuthorization();

app.MapGet("/suppliers/{id:guid}", async (Guid id, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var s = await c.QuerySingleOrDefaultAsync<Supplier>(
        @"SELECT id, code, name, contact_email AS ContactEmail, phone,
                 lead_time_days AS LeadTimeDays FROM suppliers WHERE id = @id", new { id });
    return s is null ? Results.NotFound() : Results.Ok(s);
}).RequireAuthorization();

app.MapPost("/suppliers", async (SupplierReq req, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    try
    {
        var id = await c.ExecuteScalarAsync<Guid>(
            @"INSERT INTO suppliers(code, name, contact_email, phone, lead_time_days)
              VALUES(@Code, @Name, @ContactEmail, @Phone, @LeadTimeDays) RETURNING id", req);
        return Results.Created($"/suppliers/{id}", new { id });
    }
    catch (PostgresException ex) when (ex.SqlState == "23505")
    {
        return Results.Conflict(new { error = "supplier code already exists" });
    }
}).RequireAuthorization(p => p.RequireRole("admin"));

app.MapPut("/suppliers/{id:guid}", async (Guid id, SupplierReq req, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var n = await c.ExecuteAsync(
        @"UPDATE suppliers SET name = @Name, contact_email = @ContactEmail,
                 phone = @Phone, lead_time_days = @LeadTimeDays WHERE id = @id",
        new { id, req.Name, req.ContactEmail, req.Phone, req.LeadTimeDays });
    return n == 0 ? Results.NotFound() : Results.NoContent();
}).RequireAuthorization(p => p.RequireRole("admin"));

app.MapDelete("/suppliers/{id:guid}", async (Guid id, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var n = await c.ExecuteAsync("DELETE FROM suppliers WHERE id = @id", new { id });
    return n == 0 ? Results.NotFound() : Results.NoContent();
}).RequireAuthorization(p => p.RequireRole("admin"));

app.Run();

record Supplier(Guid Id, string Code, string Name, string? ContactEmail, string? Phone, int LeadTimeDays);
record SupplierReq(string Code, string Name, string? ContactEmail, string? Phone, int LeadTimeDays);
