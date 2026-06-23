using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using OpenSearch.Client;
using Prometheus;

var builder = WebApplication.CreateBuilder(args);

var osUrl = builder.Configuration["OpenSearch:Url"] ?? "http://opensearch:9200";
var indexName = builder.Configuration["OpenSearch:Index"] ?? "parts";
var jwtKey = builder.Configuration["Jwt:Key"] ?? "dev-only-secret-please-override-32bytes-min!";
var jwtIssuer = builder.Configuration["Jwt:Issuer"] ?? "appstack";

var settings = new ConnectionSettings(new Uri(osUrl)).DefaultIndex(indexName);
builder.Services.AddSingleton(new OpenSearchClient(settings));

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

app.MapGet("/health", async (OpenSearchClient os) =>
{
    var ping = await os.PingAsync();
    return Results.Ok(new { status = "ok", service = "search", opensearch = ping.IsValid ? "up" : "down" });
});

// Full-text search against OpenSearch: multi_match over name/partNumber/description
// with fuzziness, optional category keyword filter, paged.
app.MapGet("/search", async (OpenSearchClient os, string? q, string? category,
    int page = 1, int pageSize = 20) =>
{
    pageSize = Math.Clamp(pageSize, 1, 100);
    page = Math.Max(page, 1);

    var resp = await os.SearchAsync<PartDoc>(s => s
        .From((page - 1) * pageSize)
        .Size(pageSize)
        .Query(query => query
            .Bool(b => b
                .Must(must => string.IsNullOrWhiteSpace(q)
                    ? must.MatchAll()
                    : must.MultiMatch(mm => mm
                        .Fields(f => f
                            .Field(p => p.Name, 2.0)
                            .Field(p => p.PartNumber)
                            .Field(p => p.Description))
                        .Query(q)
                        .Fuzziness(Fuzziness.Auto)))
                .Filter(filter => string.IsNullOrWhiteSpace(category)
                    ? filter.MatchAll()
                    : filter.Term(t => t.Field(p => p.Category).Value(category))))));

    if (!resp.IsValid)
        return Results.Problem(resp.OriginalException?.Message ?? resp.DebugInformation);

    var hits = resp.Hits.Select(h => new
    {
        h.Source.Id,
        h.Source.PartNumber,
        h.Source.Name,
        h.Source.Description,
        h.Source.Category,
        h.Source.UnitPrice,
        h.Source.Uom,
        h.Source.StockQty,
        score = h.Score,
    });

    return Results.Ok(new { total = resp.Total, page, pageSize, results = hits });
}).RequireAuthorization();

app.Run();

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
