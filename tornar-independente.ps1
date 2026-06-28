# tornar-independente.ps1
# Torna um site Framer estatico completamente independente de CDNs externos.

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ─── Utilitarios globais ──────────────────────────────────────────────────────

function _Count([string]$Path) {
    return @(Get-ChildItem $Path -File -ErrorAction SilentlyContinue).Count
}

# Calcula o caminho relativo de um diretorio para um arquivo, usando System.Uri
function _RelPath([string]$fromDir, [string]$toFile) {
    $from = "file:///" + $fromDir.Replace('\', '/').TrimEnd('/') + "/"
    $to   = "file:///" + $toFile.Replace('\', '/')
    $rel  = (New-Object System.Uri($from)).MakeRelativeUri((New-Object System.Uri($to))).ToString()
    return [Uri]::UnescapeDataString($rel)
}

# Download com timeout de 30 s; retorna $true em caso de sucesso
function _Download([string]$Url, [string]$Dest) {
    try {
        $req                  = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout          = 30000
        $req.ReadWriteTimeout = 30000
        $req.UserAgent        = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
        $resp = $req.GetResponse()
        $ins  = $resp.GetResponseStream()
        $outs = [System.IO.File]::Create($Dest)
        $ins.CopyTo($outs)
        $outs.Close(); $ins.Close(); $resp.Close()
        return $true
    } catch {
        Write-Host "    [ERRO] $_" -ForegroundColor Red
        if (Test-Path $Dest) { Remove-Item $Dest -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

# ─── Verificar execucao anterior ─────────────────────────────────────────────

$assetsPath = Join-Path $scriptDir "assets"

if (Test-Path $assetsPath) {
    $fC = _Count (Join-Path $assetsPath "fonts")
    $iC = _Count (Join-Path $assetsPath "images")
    $jC = _Count (Join-Path $assetsPath "js")

    Write-Host ""
    Write-Host "A pasta assets/ ja existe com:" -ForegroundColor Yellow
    Write-Host "  fonts/:  $fC arquivo(s)"
    Write-Host "  images/: $iC arquivo(s)"
    Write-Host "  js/:     $jC arquivo(s)"
    Write-Host ""
    $resp = Read-Host "Deseja executar novamente? (s/N)"
    if ($resp -notmatch '^[sS]$') {
        Write-Host "Operacao cancelada." -ForegroundColor Cyan
        exit 0
    }
}

# ─── Criar pastas de assets ───────────────────────────────────────────────────

$fontsDir  = Join-Path $assetsPath "fonts"
$imagesDir = Join-Path $assetsPath "images"
$jsDir     = Join-Path $assetsPath "js"

foreach ($d in @($fontsDir, $imagesDir, $jsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false

# Mapa: URL exata como aparece no HTML → caminho absoluto local do arquivo baixado
$urlToAbs = [System.Collections.Generic.Dictionary[string,string]]::new(
    [System.StringComparer]::Ordinal
)

# Coleta todos os .html da raiz do site, excluindo a propria pasta assets/
$htmlFiles = @(
    Get-ChildItem -Path $scriptDir -Filter "*.html" -File -Recurse |
    Where-Object { $_.FullName -notlike "*\assets\*" }
)

Write-Host ""
Write-Host "HTMLs encontrados: $($htmlFiles.Count)" -ForegroundColor White

# ─── PASSO 1: Fontes e imagens simples (sem query string) ────────────────────

Write-Host ""
Write-Host "=== PASSO 1: Fontes e imagens simples ===" -ForegroundColor Cyan

# Extensoes de fonte (sem o ponto, para classificacao abaixo)
$fontExts = @('.woff2', '.woff', '.ttf', '.otf')

# Regex: URLs de framerusercontent.com ou fonts.gstatic.com que terminam em extensao
# reconhecida e NAO possuem query string (caracter ? excluido do path pela classe [^...?#]).
$rxP1 = [regex](
    'https?://(?:framerusercontent\.com|fonts\.gstatic\.com)' +
    '/[^\s"<>?#]*\.(?:woff2|woff|ttf|otf|svg|png|jpg|jpeg|gif|webp|ico)' +
    '(?=["<>\s]|$)'
)

$seenP1 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($f in $htmlFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in $rxP1.Matches($text)) { [void]$seenP1.Add($m.Value) }
}
Write-Host "  $($seenP1.Count) URL(s) encontrada(s)."

foreach ($url in $seenP1) {
    $fn   = [System.IO.Path]::GetFileName($url)
    $ext  = [System.IO.Path]::GetExtension($url).ToLower()
    $dir  = if ($fontExts -contains $ext) { $fontsDir } else { $imagesDir }
    $dest = Join-Path $dir $fn

    if (-not (Test-Path $dest)) {
        Write-Host "  Baixando : $fn" -ForegroundColor Gray
        if (_Download $url $dest) { $urlToAbs[$url] = $dest }
    } else {
        Write-Host "  Ja existe: $fn" -ForegroundColor DarkGray
        $urlToAbs[$url] = $dest
    }
}

# ─── PASSO 2: Imagens com parametros de redimensionamento ────────────────────

Write-Host ""
Write-Host "=== PASSO 2: Imagens com parametros ===" -ForegroundColor Cyan

# Regex: URLs de imagem em framerusercontent.com/images/ QUE possuem query string.
# A classe [^\s"<>] inclui & e ; portanto captura tanto & quanto &amp; dentro da query.
$rxP2 = [regex](
    'https?://framerusercontent\.com/images/' +
    '[^\s"<>?]+\.(?:png|jpg|jpeg|gif|webp|svg|ico)' +
    '\?[^\s"<>]+'
)

# Mapa: URL base (sem ?) → nome do arquivo salvo; para baixar cada imagem apenas uma vez
$baseToFilename = [System.Collections.Generic.Dictionary[string,string]]::new(
    [System.StringComparer]::Ordinal
)

$countP2Variants = 0
foreach ($f in $htmlFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in $rxP2.Matches($text)) {
        $fullUrl = $m.Value
        if (-not $urlToAbs.ContainsKey($fullUrl)) {
            # URL base e nome do arquivo (usa o hash do Framer como nome, sem params)
            $baseUrl = $fullUrl -replace '\?.*$', ''
            $fn      = [System.IO.Path]::GetFileName($baseUrl)

            if (-not $baseToFilename.ContainsKey($baseUrl)) {
                $baseToFilename[$baseUrl] = $fn
            }

            $urlToAbs[$fullUrl] = Join-Path $imagesDir $fn
            $countP2Variants++
        }
    }
}

Write-Host "  $($baseToFilename.Count) imagem(ns) unica(s); $countP2Variants variante(s) de URL mapeada(s)."

foreach ($kv in $baseToFilename.GetEnumerator()) {
    $dest = Join-Path $imagesDir $kv.Value
    if (-not (Test-Path $dest)) {
        Write-Host "  Baixando : $($kv.Value)" -ForegroundColor Gray
        _Download $kv.Key $dest | Out-Null
    } else {
        Write-Host "  Ja existe: $($kv.Value)" -ForegroundColor DarkGray
    }
}

# ─── PASSO 3: Modulos JavaScript (.mjs e .json) ──────────────────────────────

Write-Host ""
Write-Host "=== PASSO 3: Modulos JavaScript ===" -ForegroundColor Cyan

$rxP3 = [regex]'https?://framerusercontent\.com/sites/[^\s"<>]+\.(?:mjs|json)'

$seenP3 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($f in $htmlFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($m in $rxP3.Matches($text)) { [void]$seenP3.Add($m.Value) }
}
Write-Host "  $($seenP3.Count) modulo(s) encontrado(s)."

foreach ($url in $seenP3) {
    $fn   = [System.IO.Path]::GetFileName($url)
    $dest = Join-Path $jsDir $fn

    if (-not (Test-Path $dest)) {
        Write-Host "  Baixando : $fn" -ForegroundColor Gray
        if (_Download $url $dest) { $urlToAbs[$url] = $dest }
    } else {
        Write-Host "  Ja existe: $fn" -ForegroundColor DarkGray
        $urlToAbs[$url] = $dest
    }
}

# ─── PASSO 4: Reescrever os HTMLs ────────────────────────────────────────────

Write-Host ""
Write-Host "=== PASSO 4: Atualizando HTMLs ===" -ForegroundColor Cyan

# Regex para remover a tag de analytics do Framer (qualquer ordem de atributos)
$rxAnalytics = [regex]'(?s)<script\b[^>]*\bsrc="https?://events\.framer\.com/[^"]*"[^>]*>\s*</script>'

foreach ($f in $htmlFiles) {
    $label = $f.FullName.Substring($scriptDir.Length).TrimStart('\')
    Write-Host "  $label" -ForegroundColor Gray

    $text    = [System.IO.File]::ReadAllText($f.FullName)
    $htmlDir = Split-Path $f.FullName -Parent
    $changed = $false

    # Substituir cada URL mapeada pelo caminho relativo correto para este HTML
    foreach ($kv in $urlToAbs.GetEnumerator()) {
        if ($text.Contains($kv.Key)) {
            $rel   = _RelPath -fromDir $htmlDir -toFile $kv.Value
            $text  = $text.Replace($kv.Key, $rel)
            $changed = $true
        }
    }

    # Remover script de analytics
    $t2 = $rxAnalytics.Replace($text, '<!-- analytics removido -->')
    if ($t2 -ne $text) { $text = $t2; $changed = $true }

    if ($changed) {
        [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom)
        Write-Host "    [OK] Salvo com substituicoes." -ForegroundColor Green
    } else {
        Write-Host "    Sem alteracoes." -ForegroundColor DarkGray
    }
}

# ─── RESUMO FINAL ─────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== RESUMO FINAL ===" -ForegroundColor Cyan

$fC    = _Count $fontsDir
$iC    = _Count $imagesDir
$jC    = _Count $jsDir
$total = $fC + $iC + $jC

Write-Host "  assets/fonts/:  $fC arquivo(s)"
Write-Host "  assets/images/: $iC arquivo(s)"
Write-Host "  assets/js/:     $jC arquivo(s)"
Write-Host "  Total:          $total arquivo(s)"
Write-Host ""

# Contar referencias externas restantes nos HTMLs
$rxExt  = [regex]'(?:framerusercontent\.com|fonts\.gstatic\.com)'
$refSum = 0

foreach ($f in $htmlFiles) {
    $text  = [System.IO.File]::ReadAllText($f.FullName)
    $count = $rxExt.Matches($text).Count
    $refSum += $count
    if ($count -gt 0) {
        $label = $f.FullName.Substring($scriptDir.Length).TrimStart('\')
        Write-Host "  ! $label : $count referencia(s) externa(s) restante(s)" -ForegroundColor Yellow
    }
}

Write-Host ""
if ($refSum -eq 0) {
    Write-Host "  Site 100% independente!" -ForegroundColor Green
} else {
    Write-Host "  Restam $refSum referencia(s) externas nos HTMLs." -ForegroundColor Yellow
    Write-Host "  Verifique manualmente os arquivos indicados acima." -ForegroundColor Yellow
}
Write-Host ""
