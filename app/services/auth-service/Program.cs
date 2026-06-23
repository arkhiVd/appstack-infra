using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using Dapper;
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

var app = builder.Build();
app.UseSwagger();
app.UseSwaggerUI();
app.UseHttpMetrics();

app.MapMetrics();

// Seed default admin once the DB is reachable (bcrypt can't be done in SQL).
await EnsureAdmin(app);

app.MapGet("/health", () => Results.Ok(new { status = "ok", service = "auth" }));

app.MapPost("/auth/register", async (RegisterReq req, NpgsqlDataSource db) =>
{
    if (string.IsNullOrWhiteSpace(req.Email) || string.IsNullOrWhiteSpace(req.Password))
        return Results.BadRequest(new { error = "email and password required" });

    var hash = BCrypt.Net.BCrypt.HashPassword(req.Password);
    await using var c = await db.OpenConnectionAsync();
    try
    {
        var id = await c.ExecuteScalarAsync<Guid>(
            "INSERT INTO users(email,password_hash,role) VALUES(@e,@h,'staff') RETURNING id",
            new { e = req.Email.Trim().ToLower(), h = hash });
        return Results.Created($"/users/{id}", new { id, email = req.Email, role = "staff" });
    }
    catch (PostgresException ex) when (ex.SqlState == "23505")
    {
        return Results.Conflict(new { error = "email already registered" });
    }
});

app.MapPost("/auth/login", async (LoginReq req, NpgsqlDataSource db) =>
{
    await using var c = await db.OpenConnectionAsync();
    var u = await c.QuerySingleOrDefaultAsync<UserRow>(
        "SELECT id, email, password_hash AS PasswordHash, role FROM users WHERE email=@e",
        new { e = (req.Email ?? "").Trim().ToLower() });

    if (u is null || !BCrypt.Net.BCrypt.Verify(req.Password, u.PasswordHash))
        return Results.Json(new { error = "invalid credentials" }, statusCode: 401);

    var token = MakeToken(u.Id, u.Email, u.Role, jwtKey, jwtIssuer);
    return Results.Ok(new { access_token = token, token_type = "Bearer", role = u.Role });
});

app.Run();

static string MakeToken(Guid id, string email, string role, string key, string issuer)
{
    var creds = new SigningCredentials(
        new SymmetricSecurityKey(Encoding.UTF8.GetBytes(key)), SecurityAlgorithms.HmacSha256);
    var claims = new[]
    {
        new Claim(JwtRegisteredClaimNames.Sub, id.ToString()),
        new Claim(JwtRegisteredClaimNames.Email, email),
        new Claim(ClaimTypes.Role, role),
    };
    var token = new JwtSecurityToken(
        issuer: issuer, audience: issuer, claims: claims,
        expires: DateTime.UtcNow.AddHours(8), signingCredentials: creds);
    return new JwtSecurityTokenHandler().WriteToken(token);
}

static async Task EnsureAdmin(WebApplication a)
{
    var db = a.Services.GetRequiredService<NpgsqlDataSource>();
    for (var attempt = 0; attempt < 15; attempt++)
    {
        try
        {
            await using var c = await db.OpenConnectionAsync();
            var exists = await c.ExecuteScalarAsync<bool>(
                "SELECT EXISTS(SELECT 1 FROM users WHERE email=@e)",
                new { e = "admin@appstack.local" });
            if (!exists)
            {
                var hash = BCrypt.Net.BCrypt.HashPassword("Admin123!");
                await c.ExecuteAsync(
                    "INSERT INTO users(email,password_hash,role) VALUES(@e,@h,'admin')",
                    new { e = "admin@appstack.local", h = hash });
            }
            return;
        }
        catch
        {
            await Task.Delay(2000); // DB not ready / schema not applied yet
        }
    }
}

record RegisterReq(string Email, string Password);
record LoginReq(string Email, string Password);
record UserRow(Guid Id, string Email, string PasswordHash, string Role);
