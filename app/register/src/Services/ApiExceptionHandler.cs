using Azure;
using Microsoft.AspNetCore.Diagnostics;

namespace Byok.Register.Services;

/// <summary>
/// Turns unhandled exceptions on the /api surface into ProblemDetails (#88). The app otherwise only
/// has the Blazor HTML error page, so an ARM failure reached API callers as HTML - or, worse, as a
/// raw 500 carrying Azure's error text. Azure detail is logged, never returned.
/// </summary>
internal sealed class ApiExceptionHandler : IExceptionHandler
{
    private readonly ILogger<ApiExceptionHandler> _log;

    public ApiExceptionHandler(ILogger<ApiExceptionHandler> log) => _log = log;

    public async ValueTask<bool> TryHandleAsync(HttpContext http, Exception exception, CancellationToken ct)
    {
        // Leave Blazor pages to the HTML error page; JSON only makes sense for the API surface.
        if (!http.Request.Path.StartsWithSegments("/api"))
        {
            return false;
        }

        var (status, title) = exception switch
        {
            // APIM throttling and transient ARM faults are worth retrying, so they must not look
            // like a client error. 403 is passed through because it means the app's managed
            // identity is missing a role - an operator fix, not a caller fix.
            RequestFailedException { Status: 429 } => (StatusCodes.Status503ServiceUnavailable, "Upstream is throttling; retry shortly."),
            RequestFailedException { Status: >= 500 } => (StatusCodes.Status503ServiceUnavailable, "Upstream Azure service is unavailable."),
            RequestFailedException { Status: 403 } => (StatusCodes.Status403Forbidden, "The service is not authorized to perform this operation."),
            RequestFailedException { Status: 404 } => (StatusCodes.Status404NotFound, "The requested Azure resource was not found."),
            RequestFailedException => (StatusCodes.Status502BadGateway, "The upstream Azure request failed."),
            _ => (StatusCodes.Status500InternalServerError, "The request could not be completed."),
        };

        if (exception is RequestFailedException rfe)
        {
            _log.LogError(exception, "ARM request failed: status={Status} errorCode={ErrorCode} path={Path}",
                rfe.Status, rfe.ErrorCode, http.Request.Path);
        }
        else
        {
            _log.LogError(exception, "Unhandled exception on {Path}", http.Request.Path);
        }

        http.Response.StatusCode = status;
        await http.Response.WriteAsJsonAsync(
            new { status, title }, cancellationToken: ct);
        return true;
    }
}
