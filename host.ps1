#Requires -Version 5.1
<#
  host.ps1 — zero-dependency localhost server for Field Commander.
  Serves this folder on http://localhost:<port>/ and opens the HTML app.
  Usage:   powershell -ExecutionPolicy Bypass -File .\host.ps1 [-Port 8000]
  Stop:    Ctrl+C in this window.
#>
param(
  [int]$Port = 8000,
  [string]$Entry = 'index.html'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$prefix = "http://localhost:$Port/"

$mime = @{
  '.html' = 'text/html; charset=utf-8'
  '.htm'  = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.mjs'  = 'application/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.svg'  = 'image/svg+xml'
  '.png'  = 'image/png'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.gif'  = 'image/gif'
  '.ico'  = 'image/x-icon'
  '.webp' = 'image/webp'
  '.woff' = 'font/woff'
  '.woff2'= 'font/woff2'
  '.ttf'  = 'font/ttf'
  '.pdf'  = 'application/pdf'
  '.txt'  = 'text/plain; charset=utf-8'
  '.md'   = 'text/plain; charset=utf-8'
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)

try {
  $listener.Start()
} catch [System.Net.HttpListenerException] {
  Write-Host "Could not bind to $prefix." -ForegroundColor Red
  Write-Host "Try a different port: .\host.ps1 -Port 8080" -ForegroundColor Yellow
  Write-Host "Or, if it's a permissions issue, run:"  -ForegroundColor Yellow
  Write-Host "  netsh http add urlacl url=$prefix user=$env:USERNAME" -ForegroundColor Yellow
  throw
}

$entryUrl = $prefix + [System.Uri]::EscapeDataString($Entry)
Write-Host ""
Write-Host "Field Commander local host" -ForegroundColor Cyan
Write-Host ("  Root:    {0}" -f $root)
Write-Host ("  URL:     {0}" -f $prefix)
Write-Host ("  Opening: {0}" -f $entryUrl) -ForegroundColor Green
Write-Host "  Press Ctrl+C to stop."
Write-Host ""

try { Start-Process $entryUrl | Out-Null } catch { Write-Host "(Could not auto-open browser; paste the URL above.)" -ForegroundColor Yellow }

# Graceful shutdown on Ctrl+C (best-effort; some host consoles don't expose Console handles)
try { [Console]::TreatControlCAsInput = $false } catch {}
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { if ($listener.IsListening) { $listener.Stop() } }

try {
  while ($listener.IsListening) {
    $ctxTask = $listener.GetContextAsync()
    while (-not $ctxTask.IsCompleted) { Start-Sleep -Milliseconds 50 }
    $ctx = $ctxTask.GetAwaiter().GetResult()
    $req = $ctx.Request
    $res = $ctx.Response

    try {
      $relative = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath.TrimStart('/'))
      if ([string]::IsNullOrWhiteSpace($relative)) { $relative = $Entry }

      # Resolve safely inside $root
      $full = Join-Path $root $relative
      $fullResolved = [System.IO.Path]::GetFullPath($full)
      $rootResolved = [System.IO.Path]::GetFullPath($root)
      if (-not $fullResolved.StartsWith($rootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
        $res.StatusCode = 403
        $msg = [System.Text.Encoding]::UTF8.GetBytes('403 Forbidden')
        $res.OutputStream.Write($msg, 0, $msg.Length)
        continue
      }

      if ((Test-Path $fullResolved -PathType Container)) {
        $fullResolved = Join-Path $fullResolved 'index.html'
      }

      if (-not (Test-Path $fullResolved -PathType Leaf)) {
        $res.StatusCode = 404
        $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $relative")
        $res.ContentType = 'text/plain; charset=utf-8'
        $res.OutputStream.Write($msg, 0, $msg.Length)
        Write-Host ("  404 {0}" -f $relative) -ForegroundColor DarkYellow
        continue
      }

      $ext = [System.IO.Path]::GetExtension($fullResolved).ToLowerInvariant()
      $res.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $res.Headers['Cache-Control'] = 'no-store'

      $bytes = [System.IO.File]::ReadAllBytes($fullResolved)
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      Write-Host ("  200 {0}" -f $relative) -ForegroundColor DarkGray
    } catch {
      try {
        $res.StatusCode = 500
        $msg = [System.Text.Encoding]::UTF8.GetBytes("500 Server Error: $($_.Exception.Message)")
        $res.OutputStream.Write($msg, 0, $msg.Length)
      } catch {}
      Write-Host ("  500 {0}: {1}" -f $req.Url.AbsolutePath, $_.Exception.Message) -ForegroundColor Red
    } finally {
      try { $res.OutputStream.Close() } catch {}
    }
  }
} finally {
  if ($listener.IsListening) { $listener.Stop() }
  $listener.Close()
  Write-Host "Server stopped." -ForegroundColor Cyan
}
