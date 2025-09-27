[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Users\Batista\OpenTwinPCB",
    [string]$SourceRepoUrl = "https://github.com/linkmarlon/Software",
    [string]$SourceCache = (Join-Path $env:TEMP "OpenTwinPCB_Source"),
    [string]$BuildDirName = "build"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Level = "INFO"
    )
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[$stamp][$Level] $Message"
}

function Ensure-Directory {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Log "Creating directory $Path"
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Get-FileContent {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        return [System.IO.File]::ReadAllText($Path)
    }
    return $null
}

function Set-FileContent {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Directory -Path $parent }
    $current = Get-FileContent -Path $Path
    if ($current -ne $Content) {
        Write-Log "Updating file $Path"
        [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
    }
}

function Append-UniqueLine {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Line
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { Ensure-Directory -Path $parent }
    if (-not (Test-Path -LiteralPath $Path)) {
        $Line | Out-File -FilePath $Path -Encoding UTF8
        return
    }
    $existing = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($existing -notcontains $Line) {
        $Line | Out-File -FilePath $Path -Append -Encoding UTF8
    }
}

function Ensure-GitRepo {
    param(
        [Parameter(Mandatory=$true)][string]$RepoUrl,
        [Parameter(Mandatory=$true)][string]$TargetPath
    )
    if (-not (Test-Path -LiteralPath $TargetPath)) {
        Write-Log "Cloning $RepoUrl into $TargetPath"
        git clone --depth 1 $RepoUrl $TargetPath | Out-Null
    } else {
        Write-Log "Updating repository in $TargetPath"
        Push-Location $TargetPath
        try {
            $branch = git rev-parse --abbrev-ref HEAD
            git fetch --all --prune | Out-Null
            git reset --hard origin/$branch | Out-Null
        } finally {
            Pop-Location
        }
    }
}

function Ensure-Vcpkg {
    param([string]$PreferredRoot)
    $target = $null
    if ($PreferredRoot) {
        $target = $PreferredRoot
    } elseif ($env:VCPKG_ROOT) {
        $target = $env:VCPKG_ROOT
    } else {
        $target = "C:\\vcpkg"
    }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Log "Cloning vcpkg into $target"
        git clone https://github.com/microsoft/vcpkg $target | Out-Null
        & (Join-Path $target "bootstrap-vcpkg.bat") | Out-Null
    }
    $env:VCPKG_ROOT = $target
    return $target
}

function Invoke-VcpkgInstall {
    param(
        [Parameter(Mandatory=$true)][string]$VcpkgRoot,
        [string]$Triplet = "x64-windows",
        [string]$ManifestRoot
    )
    $vcpkgExe = Join-Path $VcpkgRoot "vcpkg.exe"
    if (-not (Test-Path -LiteralPath $vcpkgExe)) {
        throw "vcpkg executable not found at $vcpkgExe"
    }
    Write-Log "Ensuring opencv installed via vcpkg manifest"
    $args = @("install", "--triplet", $Triplet)
    if ($ManifestRoot) {
        $args += "--x-manifest-root=$ManifestRoot"
    }
    & $vcpkgExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "vcpkg install failed with exit code $LASTEXITCODE"
    }
}

function Register-MissingTool {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Url,
        [string]$Note = ""
    )
    $toolsReadme = Join-Path $InstallRoot "tools\README-tools.txt"
    $line = "MISSING: $Name -> $Url $Note".Trim()
    Append-UniqueLine -Path $toolsReadme -Line $line
}

function Ensure-ExternalTool {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$WingetId,
        [string]$FallbackUrl
    )
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Log "$Name already available at $($cmd.Source)"
        return $cmd.Source
    }
    if ($WingetId) {
        try {
            Write-Log "Attempting to install $Name using winget ($WingetId)"
            winget install --id $WingetId --accept-package-agreements --accept-source-agreements -e -h | Out-Null
        } catch {
            $warnMessage = "winget installation for {0} failed: {1}" -f $Name, $_.Exception.Message
            Write-Log $warnMessage "WARN"
        }
    }
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Log "$Name available after installation"
        return $cmd.Source
    }
    if ($FallbackUrl) {
        Register-MissingTool -Name $Name -Url $FallbackUrl -Note "(automatic install unavailable)"
    }
    Write-Log "$Name not available; pipeline will degrade gracefully" "WARN"
    return $null
}

function Copy-IfNewer {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $destDir = Split-Path -Parent $Destination
    if ($destDir) { Ensure-Directory -Path $destDir }
    $copy = $true
    if (Test-Path -LiteralPath $Destination) {
        $srcTime = (Get-Item -LiteralPath $Source).LastWriteTimeUtc
        $dstTime = (Get-Item -LiteralPath $Destination).LastWriteTimeUtc
        if ($dstTime -ge $srcTime) { $copy = $false }
    }
    if ($copy) {
        Write-Log "Copying $Source -> $Destination"
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Sync-SourceRepo {
    Ensure-GitRepo -RepoUrl $SourceRepoUrl -TargetPath $SourceCache
    $docsSrc = Join-Path $SourceCache "docs"
    $examplesSrc = Join-Path $SourceCache "examples"
    $scriptsSrc = Join-Path $SourceCache "scripts"
    $inputDir = Join-Path $InstallRoot "data\input"
    Ensure-Directory -Path $inputDir
    if (Test-Path -LiteralPath $examplesSrc) {
        Get-ChildItem -Path $examplesSrc -Recurse -File | Where-Object { $_.Extension -in '.png','.jpg','.jpeg','.bmp','.tif','.tiff' } | ForEach-Object {
            $dest = Join-Path $inputDir $_.Name
            Copy-IfNewer -Source $_.FullName -Destination $dest
        }
    }
    $docsDest = Join-Path $InstallRoot "docs"
    Ensure-Directory -Path $docsDest
    if (Test-Path -LiteralPath $docsSrc) {
        Get-ChildItem -Path $docsSrc -File | ForEach-Object {
            $dest = Join-Path $docsDest $_.Name
            Copy-IfNewer -Source $_.FullName -Destination $dest
        }
    }
    if (Test-Path -LiteralPath $scriptsSrc) {
        $notesDest = Join-Path $InstallRoot "docs\upstream_scripts.md"
        $content = New-Object System.Collections.Generic.List[string]
        Get-ChildItem -Path $scriptsSrc -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($SourceCache.Length)
            $content.Add("### $relative")
            $content.Add("``````$($_.Extension.TrimStart('.'))")
            $content.Add((Get-Content -LiteralPath $_.FullName | Out-String).TrimEnd())
            $content.Add("``````")
            $content.Add("")
        }
        if ($content.Count -gt 0) {
            Set-FileContent -Path $notesDest -Content (($content -join "`n") + "`n")
        }
    }

    $summaryLines = @()
    $summaryLines += "# Upstream knowledge packs"
    $summaryLines += ""
    $summaryLines += "O repositório de origem contém principalmente PDFs e anotações que descrevem especificações e exemplos." 
    $summaryLines += "Esses materiais continuam disponíveis como referência humana; o pipeline gerado localmente fornece o código executável."
    $summaryLines += ""
    $pdfs = Get-ChildItem -Path (Join-Path $SourceCache '*') -Recurse -Filter *.pdf -ErrorAction SilentlyContinue
    if ($pdfs) {
        $summaryLines += "## PDFs referenciados"
        foreach ($pdf in $pdfs) {
            $relative = $pdf.FullName.Substring($SourceCache.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            $summaryLines += "- $relative"
        }
        $summaryLines += ""
    }
    $textual = Get-ChildItem -Path (Join-Path $SourceCache '*') -Recurse -Include *.txt,*.md,*.cpp,*.py,*.json -File -ErrorAction SilentlyContinue
    if ($textual) {
        $summaryLines += "## Arquivos de texto úteis"
        foreach ($file in $textual) {
            $relative = $file.FullName.Substring($SourceCache.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar)
            $summaryLines += "- $relative"
        }
        $summaryLines += ""
    }
    $summaryLines += "As rotinas C++/CMake, scripts PowerShell e diretórios de dados são gerados automaticamente em `src`, `include`, `tools` e `data`."
    Set-FileContent -Path (Join-Path $docsDest "knowledge_index.md") -Content (($summaryLines -join "`n") + "`n")
}
function Get-Header-Content {
@'
#pragma once

#include <string>
#include <vector>
#include <filesystem>
#include <map>
#include <fstream>
#include <opencv2/core.hpp>

namespace otpcb {

struct LayerArtifact {
    std::string name;
    std::filesystem::path input_image;
    std::filesystem::path prepared_image;
    std::filesystem::path mask_path;
    std::filesystem::path svg_path;
    std::filesystem::path dxf_path;
    std::filesystem::path metadata_path;
};

struct PipelineContext {
    std::string command;
    std::filesystem::path root;
    std::filesystem::path data_input;
    std::filesystem::path data_work;
    std::filesystem::path data_out;
    std::filesystem::path out_vectors;
    std::filesystem::path out_nets;
    std::filesystem::path out_twin;
    std::filesystem::path log_dir;
    std::filesystem::path log_file;
    std::map<std::string, std::filesystem::path> tools;
    std::vector<LayerArtifact> layers;
    std::ofstream log_stream;

    void log(const std::string& message);
};

PipelineContext make_context(const std::string& command);
void discover_layers(PipelineContext& ctx);
bool ensure_directory(const std::filesystem::path& dir);
bool write_text_file(const std::filesystem::path& path, const std::string& content);
std::string read_text_file(const std::filesystem::path& path);
std::string timestamp();
cv::Mat create_synthetic_board(int width, int height, const std::string& layer_name);
std::filesystem::path powershell_path();

void run_prep(PipelineContext& ctx);
void run_segment(PipelineContext& ctx);
void run_vectorize(PipelineContext& ctx);
void run_vias(PipelineContext& ctx);
void run_connect(PipelineContext& ctx);
void run_twin(PipelineContext& ctx);

} // namespace otpcb
'@
}
function Get-Segment-Content {
@'
#include "opentwinpcb.hpp"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>

#include <chrono>
#include <iomanip>
#include <sstream>
#include <cstdlib>

namespace otpcb {

namespace {
std::filesystem::path find_command(const std::vector<std::string>& names, const std::vector<std::filesystem::path>& hints) {
    for (const auto& hint : hints) {
        for (const auto& name : names) {
            auto candidate = hint / name;
            std::error_code ec;
            if (!candidate.empty() && std::filesystem::exists(candidate, ec)) {
                return std::filesystem::weakly_canonical(candidate, ec);
            }
        }
    }
    for (const auto& name : names) {
        std::error_code ec;
        auto p = std::filesystem::path(name);
        if (std::filesystem::exists(p, ec)) {
            return std::filesystem::weakly_canonical(p, ec);
        }
    }
    return {};
}

cv::Mat apply_orb_alignment(const cv::Mat& reference, const cv::Mat& target) {
    if (reference.empty() || target.empty()) {
        return target.clone();
    }
    auto orb = cv::ORB::create();
    std::vector<cv::KeyPoint> kp1, kp2;
    cv::Mat desc1, desc2;
    orb->detectAndCompute(reference, cv::noArray(), kp1, desc1);
    orb->detectAndCompute(target, cv::noArray(), kp2, desc2);
    if (desc1.empty() || desc2.empty()) {
        return target.clone();
    }
    auto matcher = cv::BFMatcher::create(cv::NORM_HAMMING, true);
    std::vector<cv::DMatch> matches;
    matcher->match(desc1, desc2, matches);
    if (matches.size() < 4) {
        return target.clone();
    }
    std::vector<cv::Point2f> refPts, tgtPts;
    refPts.reserve(matches.size());
    tgtPts.reserve(matches.size());
    for (const auto& m : matches) {
        refPts.push_back(kp1[m.queryIdx].pt);
        tgtPts.push_back(kp2[m.trainIdx].pt);
    }
    cv::Mat H = cv::findHomography(tgtPts, refPts, cv::RANSAC);
    if (H.empty()) {
        return target.clone();
    }
    cv::Mat aligned;
    cv::warpPerspective(target, aligned, H, reference.size());
    return aligned;
}
}

std::string timestamp() {
    auto now = std::chrono::system_clock::now();
    auto tt = std::chrono::system_clock::to_time_t(now);
    std::tm tm{};
#if defined(_WIN32)
    localtime_s(&tm, &tt);
#else
    localtime_r(&tt, &tm);
#endif
    std::ostringstream oss;
    oss << std::put_time(&tm, "%Y%m%d-%H%M%S");
    return oss.str();
}

bool ensure_directory(const std::filesystem::path& dir) {
    if (dir.empty()) {
        return false;
    }
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    return std::filesystem::exists(dir, ec);
}

std::string read_text_file(const std::filesystem::path& path) {
    if (!std::filesystem::exists(path)) {
        return {};
    }
    std::ifstream ifs(path, std::ios::binary);
    std::ostringstream oss;
    oss << ifs.rdbuf();
    return oss.str();
}

bool write_text_file(const std::filesystem::path& path, const std::string& content) {
    ensure_directory(path.parent_path());
    if (std::filesystem::exists(path)) {
        if (read_text_file(path) == content) {
            return false;
        }
    }
    std::ofstream ofs(path, std::ios::binary);
    ofs << content;
    return true;
}

std::filesystem::path powershell_path() {
#if defined(_WIN32)
    std::vector<std::filesystem::path> candidates{
        std::filesystem::path("C:/Program Files/PowerShell/7/pwsh.exe"),
        std::filesystem::path("C:/Program Files/PowerShell/7/powershell.exe"),
        std::filesystem::path("C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"),
        std::filesystem::path("pwsh.exe"),
        std::filesystem::path("powershell.exe")
    };
    for (const auto& c : candidates) {
        std::error_code ec;
        if (std::filesystem::exists(c, ec)) {
            return std::filesystem::weakly_canonical(c, ec);
        }
    }
    return std::filesystem::path("powershell.exe");
#else
    return std::filesystem::path("pwsh");
#endif
}

void PipelineContext::log(const std::string& message) {
    std::cout << "[" << command << "] " << message << std::endl;
    if (log_stream.is_open()) {
        log_stream << timestamp() << " " << message << std::endl;
    }
}

cv::Mat create_synthetic_board(int width, int height, const std::string& layer_name) {
    cv::Mat canvas(height, width, CV_8UC3, cv::Scalar(40, 40, 40));
    cv::Scalar color = layer_name.find("bottom") != std::string::npos ? cv::Scalar(0, 140, 200) : cv::Scalar(0, 200, 0);
    for (int i = 0; i < 6; ++i) {
        int offset = 30 + i * 40;
        cv::line(canvas, cv::Point(offset, 10), cv::Point(width - offset, height - 10), color, 10);
        cv::line(canvas, cv::Point(10, offset), cv::Point(width - 10, height - offset), color, 6);
    }
    cv::circle(canvas, cv::Point(width / 2, height / 2), 35, cv::Scalar(200, 200, 200), -1);
    cv::putText(canvas, layer_name, cv::Point(40, height - 40), cv::FONT_HERSHEY_SIMPLEX, 1.2, cv::Scalar(240, 240, 240), 2);
    return canvas;
}

PipelineContext make_context(const std::string& command) {
    PipelineContext ctx;
    ctx.command = command;
    std::filesystem::path root;
    if (const char* env = std::getenv("OTPCB_ROOT")) {
        root = env;
    }
    if (root.empty()) {
        root = std::filesystem::current_path();
    }
    if (!std::filesystem::exists(root)) {
        root = std::filesystem::current_path();
    }
    ctx.root = std::filesystem::weakly_canonical(root);
    ctx.data_input = ctx.root / "data" / "input";
    ctx.data_work = ctx.root / "data" / "work";
    ctx.data_out = ctx.root / "data" / "out";
    ctx.out_vectors = ctx.data_out / "vectors";
    ctx.out_nets = ctx.data_out / "nets";
    ctx.out_twin = ctx.data_out / "twin";
    ensure_directory(ctx.data_input);
    ensure_directory(ctx.data_work);
    ensure_directory(ctx.out_vectors);
    ensure_directory(ctx.out_nets);
    ensure_directory(ctx.out_twin);
    ensure_directory(ctx.root / "logs");
    auto stamp = timestamp();
    ctx.log_dir = ctx.root / "logs" / stamp;
    ensure_directory(ctx.log_dir);
    ctx.log_file = ctx.log_dir / (command + ".log");
    ctx.log_stream.open(ctx.log_file, std::ios::app);
    ctx.log("Context initialised at " + ctx.root.string());

    std::vector<std::filesystem::path> hints{
        ctx.root / "external",
        ctx.root / "external" / "ImageMagick",
        ctx.root / "external" / "potrace"
    };
    auto magick = find_command({"magick.exe", "magick"}, hints);
    if (!magick.empty()) ctx.tools["magick"] = magick;
    auto potrace = find_command({"potrace.exe", "potrace"}, hints);
    if (!potrace.empty()) ctx.tools["potrace"] = potrace;
    return ctx;
}

void discover_layers(PipelineContext& ctx) {
    ctx.layers.clear();
    std::vector<std::string> names;
    if (std::filesystem::exists(ctx.data_input)) {
        for (const auto& entry : std::filesystem::directory_iterator(ctx.data_input)) {
            if (!entry.is_regular_file()) continue;
            auto ext = entry.path().extension().string();
            std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
            if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".bmp" || ext == ".tif" || ext == ".tiff") {
                names.push_back(entry.path().stem().string());
            }
        }
    }
    if (names.empty()) {
        names = {"top", "bottom"};
    }
    for (const auto& name : names) {
        LayerArtifact art;
        art.name = name;
        art.input_image = ctx.data_input / (name + ".png");
        art.prepared_image = ctx.data_work / (name + "_prep.png");
        art.mask_path = ctx.data_work / (name + "_mask.pbm");
        art.svg_path = ctx.out_vectors / (name + ".svg");
        art.dxf_path = ctx.out_vectors / (name + ".dxf");
        art.metadata_path = ctx.data_work / (name + "_meta.json");
        ctx.layers.push_back(art);
    }
    ctx.log("Discovered " + std::to_string(ctx.layers.size()) + " layer(s)");
}

void run_prep(PipelineContext& ctx) {
    discover_layers(ctx);
    cv::Mat reference;
    for (auto& layer : ctx.layers) {
        ctx.log("Preparing layer " + layer.name);
        cv::Mat image = cv::imread(layer.input_image.string(), cv::IMREAD_COLOR);
        if (image.empty()) {
            ctx.log("Input missing for " + layer.name + ", generating synthetic sample");
            image = create_synthetic_board(1200, 900, layer.name);
            ensure_directory(layer.input_image.parent_path());
            cv::imwrite(layer.input_image.string(), image);
        }
        cv::Mat processed;
        cv::resize(image, processed, cv::Size(), 0.5, 0.5, cv::INTER_AREA);
        if (layer.name.find("bottom") != std::string::npos) {
            cv::flip(processed, processed, 1);
        }
        if (!reference.empty() && processed.size() == reference.size()) {
            processed = apply_orb_alignment(reference, processed);
        }
        if (reference.empty()) {
            reference = processed.clone();
        }
        cv::Mat lab;
        cv::cvtColor(processed, lab, cv::COLOR_BGR2Lab);
        std::vector<cv::Mat> channels;
        cv::split(lab, channels);
        auto clahe = cv::createCLAHE(3.0, cv::Size(8, 8));
        clahe->apply(channels[0], channels[0]);
        cv::merge(channels, lab);
        cv::cvtColor(lab, processed, cv::COLOR_Lab2BGR);
        ensure_directory(layer.prepared_image.parent_path());
        cv::imwrite(layer.prepared_image.string(), processed);
        std::ostringstream meta;
        meta << "{\n  \"layer\": \"" << layer.name << "\",\n  \"prepared_at\": \"" << timestamp() << "\",\n  \"source\": \"" << layer.input_image.string() << "\",\n  \"tools\": {\n    \"magick\": \"";
        if (ctx.tools.count("magick")) {
            meta << ctx.tools["magick"].string();
        }
        meta << "\"\n  }\n}\n";
        write_text_file(layer.metadata_path, meta.str());
    }
}

void run_segment(PipelineContext& ctx) {
    discover_layers(ctx);
    for (const auto& layer : ctx.layers) {
        ctx.log("Segmenting layer " + layer.name);
        cv::Mat source = cv::imread(layer.prepared_image.string(), cv::IMREAD_COLOR);
        if (source.empty()) {
            source = cv::imread(layer.input_image.string(), cv::IMREAD_COLOR);
        }
        if (source.empty()) {
            ctx.log("Unable to load image for " + layer.name);
            continue;
        }
        cv::Mat lab;
        cv::cvtColor(source, lab, cv::COLOR_BGR2Lab);
        std::vector<cv::Mat> channels;
        cv::split(lab, channels);
        auto clahe = cv::createCLAHE(3.0, cv::Size(8, 8));
        clahe->apply(channels[0], channels[0]);
        cv::Mat L = channels[0];
        cv::Mat blurred;
        cv::GaussianBlur(L, blurred, cv::Size(5, 5), 0);
        cv::Mat mask;
        cv::threshold(blurred, mask, 0, 255, cv::THRESH_BINARY | cv::THRESH_OTSU);
        cv::Mat kernel = cv::getStructuringElement(cv::MORPH_RECT, cv::Size(3, 3));
        cv::morphologyEx(mask, mask, cv::MORPH_OPEN, kernel);
        cv::morphologyEx(mask, mask, cv::MORPH_CLOSE, kernel);
        ensure_directory(layer.mask_path.parent_path());
        cv::imwrite(layer.mask_path.string(), mask);
    }
}

} // namespace otpcb
'@
}
function Get-Vectorize-Content {
@'
#include "opentwinpcb.hpp"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <cmath>
#include <sstream>

namespace otpcb {

namespace {
struct VectorMeta {
    std::string track_id;
    std::string layer;
    cv::Rect bbox;
    double perimeter{0.0};
    double area{0.0};
};

std::string rect_to_string(const cv::Rect& r) {
    std::ostringstream oss;
    oss << "[" << r.x << ", " << r.y << ", " << r.width << ", " << r.height << "]";
    return oss.str();
}

void write_svg(const std::filesystem::path& path, const cv::Size& size, const std::vector<std::vector<cv::Point>>& contours) {
    std::ostringstream svg;
    svg << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
    svg << "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" << size.width << "\" height=\"" << size.height << "\" viewBox=\"0 0 " << size.width << " " << size.height << "\">\n";
    svg << "  <g fill=\"none\" stroke=\"#ff8800\" stroke-width=\"1\">\n";
    for (const auto& contour : contours) {
        if (contour.empty()) continue;
        svg << "    <path d=\"M";
        for (size_t i = 0; i < contour.size(); ++i) {
            svg << contour[i].x << " " << contour[i].y;
            if (i + 1 < contour.size()) {
                svg << " L";
            }
        }
        svg << "Z\"/>\n";
    }
    svg << "  </g>\n</svg>\n";
    write_text_file(path, svg.str());
}

void write_dxf(const std::filesystem::path& path, const std::vector<std::vector<cv::Point>>& contours) {
    std::ostringstream dxf;
    dxf << "0\nSECTION\n2\nENTITIES\n";
    for (const auto& contour : contours) {
        if (contour.size() < 2) continue;
        dxf << "0\nLWPOLYLINE\n8\nCOPPER\n90\n" << contour.size() << "\n";
        for (const auto& pt : contour) {
            dxf << "10\n" << pt.x << "\n20\n" << pt.y << "\n";
        }
        dxf << "70\n1\n";
    }
    dxf << "0\nENDSEC\n0\nEOF\n";
    write_text_file(path, dxf.str());
}

void append_meta_csv(const std::filesystem::path& path, const std::vector<VectorMeta>& entries) {
    std::ostringstream csv;
    if (!std::filesystem::exists(path)) {
        csv << "track_id,layer,x,y,width,height,perimeter,area\n";
    }
    for (const auto& meta : entries) {
        csv << meta.track_id << "," << meta.layer << "," << meta.bbox.x << "," << meta.bbox.y << "," << meta.bbox.width << "," << meta.bbox.height << "," << meta.perimeter << "," << meta.area << "\n";
    }
    std::ofstream ofs(path, std::ios::app | std::ios::binary);
    ofs << csv.str();
}
}

void run_vectorize(PipelineContext& ctx) {
    discover_layers(ctx);
    std::vector<VectorMeta> all;
    std::filesystem::path csvPath = ctx.data_work / "vector_meta.csv";
    if (std::filesystem::exists(csvPath)) {
        std::filesystem::remove(csvPath);
    }
    for (const auto& layer : ctx.layers) {
        ctx.log("Vectorising layer " + layer.name);
        cv::Mat mask = cv::imread(layer.mask_path.string(), cv::IMREAD_GRAYSCALE);
        if (mask.empty()) {
            ctx.log("Mask missing for " + layer.name + ", attempting to re-run segmentation");
            run_segment(ctx);
            mask = cv::imread(layer.mask_path.string(), cv::IMREAD_GRAYSCALE);
        }
        if (mask.empty()) {
            ctx.log("Unable to vectorise layer " + layer.name + " due to missing mask");
            continue;
        }
        std::vector<std::vector<cv::Point>> contours;
        cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);
        std::vector<VectorMeta> metas;
        for (size_t i = 0; i < contours.size(); ++i) {
            if (contours[i].size() < 3) continue;
            VectorMeta meta;
            meta.track_id = layer.name + "_" + std::to_string(i);
            meta.layer = layer.name;
            meta.bbox = cv::boundingRect(contours[i]);
            meta.perimeter = cv::arcLength(contours[i], true);
            meta.area = cv::contourArea(contours[i]);
            metas.push_back(meta);
        }
        write_svg(layer.svg_path, mask.size(), contours);
        write_dxf(layer.dxf_path, contours);
        append_meta_csv(csvPath, metas);
        all.insert(all.end(), metas.begin(), metas.end());

        if (ctx.tools.count("potrace")) {
            auto potrace = ctx.tools["potrace"].string();
            std::ostringstream cmd;
            cmd << "\"" << potrace << "\" \"" << layer.mask_path.string() << "\" -s -o \"" << layer.svg_path.string() << "\"";
            std::system(cmd.str().c_str());
            std::ostringstream cmdDxf;
            cmdDxf << "\"" << potrace << "\" \"" << layer.mask_path.string() << "\" -b dxf -o \"" << layer.dxf_path.string() << "\"";
            std::system(cmdDxf.str().c_str());
        }
    }
    std::ostringstream index;
    index << "{\n  \"generated\": \"" << timestamp() << "\",\n  \"vectors\": [\n";
    for (size_t i = 0; i < all.size(); ++i) {
        const auto& meta = all[i];
        index << "    {\n      \"track_id\": \"" << meta.track_id << "\",\n      \"layer\": \"" << meta.layer << "\",\n      \"bbox\": " << rect_to_string(meta.bbox) << ",\n      \"perimeter\": " << meta.perimeter << ",\n      \"area\": " << meta.area << "\n    }";
        if (i + 1 != all.size()) index << ",";
        index << "\n";
    }
    index << "  ]\n}\n";
    write_text_file(ctx.out_vectors / "index.json", index.str());
}

} // namespace otpcb
'@
}
function Get-Vias-Content {
@'
#include "opentwinpcb.hpp"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <sstream>

namespace otpcb {

void run_vias(PipelineContext& ctx) {
    discover_layers(ctx);
    std::vector<std::string> records;
    records.push_back("via_id,x,y,diameter,layers");
    int viaCounter = 0;
    std::ostringstream json;
    json << "{\n  \"generated\": \"" << timestamp() << "\",\n  \"vias\": [\n";
    bool first = true;
    for (const auto& layer : ctx.layers) {
        ctx.log("Detecting vias on " + layer.name);
        cv::Mat source = cv::imread(layer.prepared_image.string(), cv::IMREAD_GRAYSCALE);
        if (source.empty()) {
            source = cv::imread(layer.input_image.string(), cv::IMREAD_GRAYSCALE);
        }
        if (source.empty()) continue;
        cv::Mat blurred;
        cv::GaussianBlur(source, blurred, cv::Size(9, 9), 2);
        std::vector<cv::Vec3f> circles;
        cv::HoughCircles(blurred, circles, cv::HOUGH_GRADIENT, 1, 50, 150, 30, 4, 60);
        for (const auto& c : circles) {
            std::string viaId = "via" + std::to_string(viaCounter++);
            if (!first) json << ",\n";
            first = false;
            json << "    {\n      \"id\": \"" << viaId << "\",\n      \"x\": " << c[0] << ",\n      \"y\": " << c[1] << ",\n      \"diameter\": " << c[2] * 2 << ",\n      \"layers\": [\"" << layer.name << "\"]\n    }";
            std::ostringstream csvLine;
            csvLine << viaId << "," << c[0] << "," << c[1] << "," << c[2] * 2 << "," << layer.name;
            records.push_back(csvLine.str());
        }
    }
    json << "\n  ]\n}\n";
    write_text_file(ctx.data_out / "vias.json", json.str());
    std::ostringstream csvContent;
    for (const auto& line : records) {
        csvContent << line << "\n";
    }
    write_text_file(ctx.data_work / "vias.csv", csvContent.str());
}

} // namespace otpcb
'@
}
function Get-Connect-Content {
@'
#include "opentwinpcb.hpp"

#include <opencv2/core.hpp>

#include <sstream>
#include <unordered_map>

namespace otpcb {

namespace {
struct Node {
    std::string id;
    std::string layer;
    cv::Rect bbox;
};

struct Via {
    std::string id;
    cv::Point2d center;
    double diameter{0.0};
    std::vector<std::string> layers;
};

struct DisjointSet {
    std::vector<int> parent;
    int find(int x) {
        if (parent[x] == x) return x;
        parent[x] = find(parent[x]);
        return parent[x];
    }
    void unite(int a, int b) {
        int ra = find(a);
        int rb = find(b);
        if (ra != rb) parent[rb] = ra;
    }
};

std::vector<Node> load_nodes(const std::filesystem::path& csvPath) {
    std::vector<Node> nodes;
    if (!std::filesystem::exists(csvPath)) return nodes;
    std::ifstream ifs(csvPath);
    std::string line;
    std::getline(ifs, line);
    while (std::getline(ifs, line)) {
        if (line.empty()) continue;
        std::stringstream ss(line);
        Node node;
        std::string token;
        std::getline(ss, node.id, ',');
        std::getline(ss, node.layer, ',');
        std::getline(ss, token, ',');
        int x = std::stoi(token);
        std::getline(ss, token, ',');
        int y = std::stoi(token);
        std::getline(ss, token, ',');
        int w = std::stoi(token);
        std::getline(ss, token, ',');
        int h = std::stoi(token);
        node.bbox = cv::Rect(x, y, w, h);
        nodes.push_back(node);
    }
    return nodes;
}

std::vector<Via> load_vias(const std::filesystem::path& csvPath) {
    std::vector<Via> vias;
    if (!std::filesystem::exists(csvPath)) return vias;
    std::ifstream ifs(csvPath);
    std::string line;
    std::getline(ifs, line);
    while (std::getline(ifs, line)) {
        if (line.empty()) continue;
        std::stringstream ss(line);
        Via via;
        std::string token;
        std::getline(ss, via.id, ',');
        std::getline(ss, token, ',');
        via.center.x = std::stod(token);
        std::getline(ss, token, ',');
        via.center.y = std::stod(token);
        std::getline(ss, token, ',');
        via.diameter = std::stod(token);
        std::getline(ss, token, ',');
        if (!token.empty()) via.layers.push_back(token);
        vias.push_back(via);
    }
    return vias;
}

bool overlaps(const cv::Rect& a, const cv::Rect& b) {
    return (a & b).area() > 0;
}

bool touches_via(const Node& node, const Via& via) {
    cv::Rect expanded = node.bbox;
    expanded.x -= static_cast<int>(via.diameter / 2);
    expanded.y -= static_cast<int>(via.diameter / 2);
    expanded.width += static_cast<int>(via.diameter);
    expanded.height += static_cast<int>(via.diameter);
    return expanded.contains(via.center);
}
}

void run_connect(PipelineContext& ctx) {
    ctx.log("Building connectivity graph");
    auto nodes = load_nodes(ctx.data_work / "vector_meta.csv");
    auto vias = load_vias(ctx.data_work / "vias.csv");
    int total = static_cast<int>(nodes.size() + vias.size());
    DisjointSet dsu;
    dsu.parent.resize(total);
    for (int i = 0; i < total; ++i) dsu.parent[i] = i;

    for (size_t i = 0; i < nodes.size(); ++i) {
        for (size_t j = i + 1; j < nodes.size(); ++j) {
            if (nodes[i].layer == nodes[j].layer && overlaps(nodes[i].bbox, nodes[j].bbox)) {
                dsu.unite(static_cast<int>(i), static_cast<int>(j));
            }
        }
    }

    for (size_t v = 0; v < vias.size(); ++v) {
        size_t viaIndex = nodes.size() + v;
        for (size_t n = 0; n < nodes.size(); ++n) {
            if (touches_via(nodes[n], vias[v])) {
                dsu.unite(static_cast<int>(viaIndex), static_cast<int>(n));
            }
        }
    }

    std::unordered_map<int, std::vector<std::string>> netMembers;
    for (size_t i = 0; i < nodes.size(); ++i) {
        int root = dsu.find(static_cast<int>(i));
        netMembers[root].push_back(nodes[i].id);
    }
    for (size_t v = 0; v < vias.size(); ++v) {
        int root = dsu.find(static_cast<int>(nodes.size() + v));
        netMembers[root].push_back(vias[v].id);
    }

    std::ostringstream netlist;
    netlist << "(export (version D)\n  (components)\n  (nets\n";
    int netCode = 1;
    std::ostringstream skidl;
    skidl << "# Auto-generated SKiDL nets\nfrom skidl import Net\n\n";
    for (const auto& entry : netMembers) {
        if (entry.second.empty()) continue;
        std::string netName = "NET" + std::to_string(netCode);
        netlist << "    (net (code " << netCode << ") (name \"" << netName << "\")\n";
        skidl << netName << " = Net('" << netName << "')\n";
        for (const auto& member : entry.second) {
            netlist << "      (node (ref " << member << ") (pin 1))\n";
            skidl << netName << ".add('\"" << member << "\"')\n";
        }
        netlist << "    )\n";
        skidl << "\n";
        ++netCode;
    }
    netlist << "  )\n)\n";
    write_text_file(ctx.out_nets / "otpcb.net", netlist.str());
    write_text_file(ctx.out_nets / "skidl.py", skidl.str());
}

} // namespace otpcb
'@
}
function Get-Twin-Content {
@'
#include "opentwinpcb.hpp"

#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>

#include <numeric>
#include <sstream>

namespace otpcb {

namespace {
std::string escape_json(const std::string& value) {
    std::ostringstream oss;
    for (char c : value) {
        switch (c) {
        case '\\': oss << "\\\\"; break;
        case '"': oss << "\\\""; break;
        case '\n': oss << "\\n"; break;
        default: oss << c; break;
        }
    }
    return oss.str();
}

double mask_coverage(const cv::Mat& mask) {
    if (mask.empty()) return 0.0;
    double sumVal = cv::sum(mask > 0)[0];
    double total = mask.total();
    return total > 0 ? sumVal / total : 0.0;
}

void copy_if_exists(const std::filesystem::path& src, const std::filesystem::path& dst) {
    std::error_code ec;
    if (!std::filesystem::exists(src)) return;
    ensure_directory(dst.parent_path());
    std::filesystem::copy_file(src, dst, std::filesystem::copy_options::overwrite_existing, ec);
}
}

void run_twin(PipelineContext& ctx) {
    discover_layers(ctx);
    std::vector<std::string> vectorLines;
    if (std::filesystem::exists(ctx.data_work / "vector_meta.csv")) {
        std::ifstream ifs(ctx.data_work / "vector_meta.csv");
        std::string line;
        while (std::getline(ifs, line)) {
            if (!line.empty()) vectorLines.push_back(line);
        }
    }
    std::vector<std::string> viaLines;
    if (std::filesystem::exists(ctx.data_work / "vias.csv")) {
        std::ifstream ifs(ctx.data_work / "vias.csv");
        std::string line;
        while (std::getline(ifs, line)) {
            if (!line.empty()) viaLines.push_back(line);
        }
    }
    int netsCount = 0;
    auto netPath = ctx.out_nets / "otpcb.net";
    if (std::filesystem::exists(netPath)) {
        std::ifstream ifs(netPath);
        std::string line;
        while (std::getline(ifs, line)) {
            if (line.find("(net (code") != std::string::npos) {
                ++netsCount;
            }
        }
    }

    double coverageSum = 0.0;
    int coverageCount = 0;
    for (const auto& layer : ctx.layers) {
        cv::Mat mask = cv::imread(layer.mask_path.string(), cv::IMREAD_GRAYSCALE);
        if (!mask.empty()) {
            coverageSum += mask_coverage(mask);
            ++coverageCount;
        }
    }
    double avgCoverage = coverageCount > 0 ? coverageSum / coverageCount : 0.0;

    std::ostringstream json;
    json << "{\n";
    json << "  \"generated\": \"" << timestamp() << "\",\n";
    json << "  \"layers\": " << ctx.layers.size() << ",\n";
    json << "  \"tracks\": " << (vectorLines.size() > 0 ? static_cast<int>(vectorLines.size() - 1) : 0) << ",\n";
    json << "  \"vias\": " << (viaLines.size() > 0 ? static_cast<int>(viaLines.size() - 1) : 0) << ",\n";
    json << "  \"nets\": " << netsCount << ",\n";
    json << "  \"metrics\": {\n";
    json << "    \"average_mask_coverage\": " << avgCoverage << "\n";
    json << "  },\n";
    json << "  \"artifacts\": {\n";
    for (size_t i = 0; i < ctx.layers.size(); ++i) {
        const auto& layer = ctx.layers[i];
        json << "    \"" << escape_json(layer.name) << "\": {\n";
        json << "      \"prepared\": \"" << escape_json(layer.prepared_image.string()) << "\",\n";
        json << "      \"mask\": \"" << escape_json(layer.mask_path.string()) << "\"\n";
        json << "    }";
        if (i + 1 != ctx.layers.size()) json << ",";
        json << "\n";
    }
    json << "  }\n";
    json << "}\n";

    auto twinJsonPath = ctx.out_twin / "twin.json";
    write_text_file(twinJsonPath, json.str());

    auto bundleRoot = ctx.out_twin / "bundle";
    ensure_directory(bundleRoot);
    ensure_directory(bundleRoot / "images");
    ensure_directory(bundleRoot / "vectors");
    ensure_directory(bundleRoot / "nets");
    ensure_directory(bundleRoot / "reports");

    for (const auto& layer : ctx.layers) {
        copy_if_exists(layer.prepared_image, bundleRoot / "images" / layer.prepared_image.filename());
        copy_if_exists(layer.mask_path, bundleRoot / "images" / layer.mask_path.filename());
        copy_if_exists(layer.svg_path, bundleRoot / "vectors" / layer.svg_path.filename());
        copy_if_exists(layer.dxf_path, bundleRoot / "cad" / layer.dxf_path.filename());
    }
    copy_if_exists(ctx.out_vectors / "index.json", bundleRoot / "reports" / "vectors_index.json");
    copy_if_exists(ctx.data_out / "vias.json", bundleRoot / "reports" / "vias.json");
    copy_if_exists(ctx.out_nets / "otpcb.net", bundleRoot / "nets" / "otpcb.net");
    copy_if_exists(ctx.out_nets / "skidl.py", bundleRoot / "nets" / "skidl.py");
    copy_if_exists(twinJsonPath, bundleRoot / "reports" / "twin.json");

    auto packagePath = ctx.out_twin / "MyBoard.otptwin";
    auto ps = powershell_path();
    std::ostringstream cmd;
    std::string bundleGlob = (bundleRoot / "*").string();
    for (auto& ch : bundleGlob) {
        if (ch == '\\') ch = '/';
    }
    std::string packageStr = packagePath.string();
    for (auto& ch : packageStr) {
        if (ch == '\\') ch = '/';
    }
    cmd << "\"" << ps.string() << "\" -NoProfile -Command \"Compress-Archive -Path '" << bundleGlob << "' -DestinationPath '" << packageStr << "' -Force\"";
    int result = std::system(cmd.str().c_str());
    if (result != 0) {
        ctx.log("Failed to create .otptwin via Compress-Archive, writing placeholder");
        write_text_file(packagePath, "OpenTwinPCB bundle creation failed: see logs.");
    }
}

} // namespace otpcb
'@
}
function Get-MainCli-Content {
@'
#include "opentwinpcb.hpp"

#include <iostream>
#include <algorithm>

#if defined(_WIN32)
#include <cstdlib>
#endif

namespace {
void print_usage() {
    std::cout << "Usage: otpcb_cli <command> [--root <path>]" << std::endl;
    std::cout << "Commands: prep, segment, vector, vias, connect, twin, all" << std::endl;
}

void set_root_env(const std::string& root) {
#if defined(_WIN32)
    _putenv_s("OTPCB_ROOT", root.c_str());
#else
    setenv("OTPCB_ROOT", root.c_str(), 1);
#endif
}
}

int main(int argc, char** argv) {
    if (argc < 2) {
        print_usage();
        return 1;
    }
    std::string command = argv[1];
    std::string rootOverride;
    for (int i = 2; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--root" && i + 1 < argc) {
            rootOverride = argv[++i];
        } else if (arg.rfind("--root=", 0) == 0) {
            rootOverride = arg.substr(7);
        }
    }
    if (!rootOverride.empty()) {
        set_root_env(rootOverride);
    }

    try {
        auto ctx = otpcb::make_context(command);
        auto execute_all = [&]() {
            otpcb::run_prep(ctx);
            otpcb::run_segment(ctx);
            otpcb::run_vectorize(ctx);
            otpcb::run_vias(ctx);
            otpcb::run_connect(ctx);
            otpcb::run_twin(ctx);
        };
        if (command == "prep") {
            otpcb::run_prep(ctx);
        } else if (command == "segment") {
            otpcb::run_segment(ctx);
        } else if (command == "vector") {
            otpcb::run_vectorize(ctx);
        } else if (command == "vias") {
            otpcb::run_vias(ctx);
        } else if (command == "connect") {
            otpcb::run_connect(ctx);
        } else if (command == "twin") {
            otpcb::run_twin(ctx);
        } else if (command == "all" || command == "pipeline") {
            execute_all();
        } else {
            print_usage();
            return 1;
        }
    } catch (const std::exception& ex) {
        std::cerr << "Error: " << ex.what() << std::endl;
        return 2;
    }
    return 0;
}
'@
}
function Get-CMakeLists-Content {
@'
cmake_minimum_required(VERSION 3.20)

project(OpenTwinPCB LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

find_package(OpenCV REQUIRED)
find_package(Potrace QUIET)

add_library(opentwinpcb_core STATIC
    src/core/segment.cpp
    src/core/vectorize.cpp
    src/core/vias.cpp
    src/core/connect.cpp
    src/core/twin.cpp
)

target_include_directories(opentwinpcb_core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(opentwinpcb_core
    PUBLIC
        ${OpenCV_LIBS}
)

if(Potrace_FOUND)
    target_compile_definitions(opentwinpcb_core PUBLIC OTPCB_POTRACE_AVAILABLE)
    target_include_directories(opentwinpcb_core PUBLIC ${POTRACE_INCLUDE_DIR})
    target_link_libraries(opentwinpcb_core PUBLIC ${POTRACE_LIBRARY})
endif()

add_executable(otpcb_cli src/cli/main_cli.cpp)
target_link_libraries(otpcb_cli PRIVATE opentwinpcb_core)

if(MSVC)
    target_compile_options(opentwinpcb_core PRIVATE /W4 /permissive-)
    target_compile_options(otpcb_cli PRIVATE /W4 /permissive-)
else()
    target_compile_options(opentwinpcb_core PRIVATE -Wall -Wextra -Wpedantic)
    target_compile_options(otpcb_cli PRIVATE -Wall -Wextra -Wpedantic)
endif()

install(TARGETS otpcb_cli RUNTIME DESTINATION bin)
'@
}
function Get-Vcpkg-Content {
@'
{
  "name": "opentwinpcb",
  "version-string": "0.1.0",
  "builtin-baseline": "__VCPKG_BASELINE__",
  "dependencies": [
    {
      "name": "opencv",
      "version>=": "4.8.0"
    }
  ]
}
'@
}

function Update-VcpkgManifestBaseline {
    param(
        [Parameter(Mandatory=$true)][string]$VcpkgRoot
    )
    $manifestPath = Join-Path $InstallRoot "vcpkg.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    $baseline = $null
    try {
        $baseline = (git -C $VcpkgRoot rev-parse HEAD).Trim()
    } catch {
        Write-Log "Failed to obtain vcpkg baseline commit: $($_.Exception.Message)" "WARN"
        return
    }
    if ([string]::IsNullOrWhiteSpace($baseline)) { return }
    $content = Get-Content -LiteralPath $manifestPath -Raw
    if (-not $content) { return }
    $updated = $content
    if ($updated -match "__VCPKG_BASELINE__") {
        $updated = $updated -replace "__VCPKG_BASELINE__", $baseline
    } else {
        $pattern = '"builtin-baseline"\s*:\s*"[0-9a-f]+"'
        if ($updated -match $pattern) {
            $updated = [System.Text.RegularExpressions.Regex]::Replace($updated, $pattern, '"builtin-baseline": "' + $baseline + '"')
        }
    }
    if ($updated -ne $content) {
        Set-FileContent -Path $manifestPath -Content $updated
    }
}
function Get-FindPotrace-Content {
@'
find_path(POTRACE_INCLUDE_DIR potrace/potracelib.h
    HINTS
        ${CMAKE_CURRENT_LIST_DIR}/../external/potrace/include
        ENV POTRACE_INCLUDE
)

find_library(POTRACE_LIBRARY NAMES potrace
    HINTS
        ${CMAKE_CURRENT_LIST_DIR}/../external/potrace/lib
        ENV POTRACE_LIB
)

include(FindPackageHandleStandardArgs)
find_package_handle_standard_args(Potrace DEFAULT_MSG POTRACE_LIBRARY POTRACE_INCLUDE_DIR)

mark_as_advanced(POTRACE_LIBRARY POTRACE_INCLUDE_DIR)
'@
}
function Get-FetchTools-Content {
@'
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
)

$ErrorActionPreference = "Stop"

function Ensure-Tool {
    param(
        [string]$Name,
        [string]$Command,
        [string]$WingetId,
        [string]$Url
    )
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "$Name already installed at $($cmd.Source)"
        return $cmd.Source
    }
    if ($WingetId) {
        try {
            Write-Host "Attempting winget installation for $Name ($WingetId)"
            winget install --id $WingetId --accept-package-agreements --accept-source-agreements -e -h | Out-Null
        } catch {
            $warn = "winget failed for {0}: {1}" -f $Name, $_.Exception.Message
            Write-Warning $warn
        }
    }
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) {
        Write-Host "$Name installed via winget"
        return $cmd.Source
    }
    $readme = Join-Path $Root "tools\README-tools.txt"
    if ($Url) {
        "MISSING: $Name -> $Url" | Out-File -FilePath $readme -Append -Encoding UTF8
    }
    Write-Warning "$Name unavailable; recorded in README"
    return $null
}

Ensure-Tool -Name "ImageMagick" -Command "magick" -WingetId "ImageMagick.ImageMagick" -Url "https://imagemagick.org/script/download.php"
Ensure-Tool -Name "Potrace" -Command "potrace" -WingetId "" -Url "http://potrace.sourceforge.net/"
Ensure-Tool -Name "Fiji" -Command "ImageJ-win64" -WingetId "" -Url "https://imagej.net/software/fiji/"
'@
}
function Get-QuickTest-Content {
@'
[CmdletBinding()]
param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
    [string]$Configuration = "Release",
    [string]$BuildDirName = "build"
)

$ErrorActionPreference = "Stop"
$buildDir = Join-Path $Root $BuildDirName
$candidates = @(
    Join-Path $buildDir "$Configuration\otpcb_cli.exe",
    Join-Path $buildDir "otpcb_cli.exe"
)
$cli = $null
foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
        $cli = $candidate
        break
    }
}
if (-not $cli) {
    Write-Warning "otpcb_cli.exe not found; quick test skipped"
    return
}
$env:OTPCB_ROOT = $Root
$commands = @("prep","segment","vector","vias","connect","twin")
foreach ($cmd in $commands) {
    Write-Host "Running $cmd"
    & $cli $cmd --root $Root | Tee-Object -FilePath (Join-Path $Root "logs\quick_test_$cmd.log") -Append
}
'@
}
function Get-ToolsReadme-Content {
@'
# External Tools Notes

This file tracks external binaries required by the OpenTwinPCB pipeline. The setup script
will attempt to download or install them automatically. When a tool cannot be fetched the
script records a pointer here while still allowing the build to continue.

* ImageMagick (`magick`): used for optional deskew and resampling during `prep`.
* Potrace (`potrace`): used for raster-to-vector conversion during `vector`.
* Fiji/ImageJ: optional for more advanced preprocessing; currently unused but documented.

Lines prefixed with `MISSING:` are generated automatically.
'@
}
function Get-DataReadme-Content {
@'
This directory contains intermediate working data for the OpenTwinPCB pipeline.
The setup script ensures the following structure:
- data/input: source PCB images
- data/work: preprocessed images, masks, metadata
- data/out: generated artifacts (vectors, nets, twin packages)
- logs: execution logs grouped by timestamp
'@
}

function Get-PwshPath {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return $pwsh.Source }
    $powershell = Get-Command powershell -ErrorAction SilentlyContinue
    if ($powershell) { return $powershell.Source }
    return "powershell"
}

function Write-ProjectFiles {
    Ensure-Directory -Path $InstallRoot
    foreach ($folder in @("cmake","external","include","src\core","src\cli","tools","data\input","data\work","data\out","data\out\vectors","data\out\nets","data\out\twin","data\work","logs")) {
        Ensure-Directory -Path (Join-Path $InstallRoot $folder)
    }
    Set-FileContent -Path (Join-Path $InstallRoot "CMakeLists.txt") -Content (Get-CMakeLists-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "vcpkg.json") -Content (Get-Vcpkg-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "cmake\FindPotrace.cmake") -Content (Get-FindPotrace-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "include\opentwinpcb.hpp") -Content (Get-Header-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "src\core\segment.cpp") -Content (Get-Segment-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "src\core\vectorize.cpp") -Content (Get-Vectorize-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "src\core\vias.cpp") -Content (Get-Vias-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "src\core\connect.cpp") -Content (Get-Connect-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "src\core\twin.cpp") -Content (Get-Twin-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "src\cli\main_cli.cpp") -Content (Get-MainCli-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "tools\fetch_tools.ps1") -Content (Get-FetchTools-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "tools\quick_test.ps1") -Content (Get-QuickTest-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "tools\README-tools.txt") -Content (Get-ToolsReadme-Content)
    Set-FileContent -Path (Join-Path $InstallRoot "data\README.txt") -Content (Get-DataReadme-Content)
}

function Invoke-FetchTools {
    $fetch = Join-Path $InstallRoot "tools\fetch_tools.ps1"
    if (Test-Path -LiteralPath $fetch) {
        $pwsh = Get-PwshPath
        try {
            Write-Log "Running fetch_tools script"
            & $pwsh -NoProfile -ExecutionPolicy Bypass -File $fetch -Root $InstallRoot
        } catch {
            Write-Log "fetch_tools.ps1 failed: $($_.Exception.Message)" "WARN"
        }
    }
}

function Invoke-CMakeBuild {
    param(
        [string]$VcpkgRoot
    )
    $buildDir = Join-Path $InstallRoot $BuildDirName
    Ensure-Directory -Path $buildDir
    $toolchain = Join-Path $VcpkgRoot "scripts\buildsystems\vcpkg.cmake"
    $configureArgs = @("-S", $InstallRoot, "-B", $buildDir, "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_TOOLCHAIN_FILE=$toolchain")
    $generator = $env:OTPCB_CMAKE_GENERATOR
    if (-not $generator) {
        if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
            $generator = "Visual Studio 17 2022"
        } elseif (Get-Command ninja -ErrorAction SilentlyContinue) {
            $generator = "Ninja"
        }
    }
    if ($generator) {
        $configureArgs += "-G"
        $configureArgs += $generator
        if ($generator -like "Visual Studio*") {
            $configureArgs += "-A"
            $configureArgs += "x64"
        }
    }
    Write-Log "Configuring project with CMake"
    & cmake @configureArgs
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configure failed with exit code $LASTEXITCODE"
    }
    Write-Log "Building project"
    & cmake --build $buildDir --config Release
    if ($LASTEXITCODE -ne 0) {
        throw "CMake build failed with exit code $LASTEXITCODE"
    }
}

function Invoke-QuickTest {
    $quick = Join-Path $InstallRoot "tools\quick_test.ps1"
    if (-not (Test-Path -LiteralPath $quick)) { return }
    $pwsh = Get-PwshPath
    Write-Log "Executing quick_test pipeline"
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File $quick -Root $InstallRoot -Configuration Release -BuildDirName $BuildDirName
}

function Validate-Artifacts {
    $maskFiles = Get-ChildItem -Path (Join-Path $InstallRoot "data\work") -Filter "*_mask.pbm" -ErrorAction SilentlyContinue
    if (-not $maskFiles) { throw "No segmentation mask files were generated." }
    $svgFiles = Get-ChildItem -Path (Join-Path $InstallRoot "data\out\vectors") -Filter "*.svg" -ErrorAction SilentlyContinue
    if (-not $svgFiles) { throw "No vector SVG files generated." }
    foreach ($required in @(
        "data\out\vias.json",
        "data\out\nets\otpcb.net",
        "data\out\twin\twin.json",
        "data\out\twin\MyBoard.otptwin"
    )) {
        $path = Join-Path $InstallRoot $required
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Required artifact missing: $required"
        }
    }
}

function Main {
    try {
        Write-Log "Starting OpenTwinPCB setup"
        Write-ProjectFiles
        try {
            Sync-SourceRepo
        } catch {
            Write-Log "Source repo sync failed: $($_.Exception.Message)" "WARN"
        }
        $vcpkgRoot = Ensure-Vcpkg
        Update-VcpkgManifestBaseline -VcpkgRoot $vcpkgRoot
        Invoke-VcpkgInstall -VcpkgRoot $vcpkgRoot -ManifestRoot $InstallRoot
        Invoke-FetchTools
        Invoke-CMakeBuild -VcpkgRoot $vcpkgRoot
        Invoke-QuickTest
        Validate-Artifacts
        Write-Log "Setup completed successfully"
    } catch {
        Write-Log "Setup failed: $($_.Exception.Message)" "ERROR"
        throw
    }
}

Main
