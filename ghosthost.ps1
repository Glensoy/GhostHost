
# ==========================================
# WEBSITE BLOCKING MANAGER
# Run as Administrator
# Source of truth: Windows hosts file
# ==========================================

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
$backupPath = "$hostsPath.bak"

# Check administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Run this script as Administrator!" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

if (-not (Test-Path $hostsPath)) {
    Write-Host "Hosts file not found: $hostsPath" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# Read actual hosts file every time this function is called
function Get-HostsLines {
    @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
}

# Extract domains mapped to localhost/blocking addresses
function Get-Sites {
    $found = @(
        foreach ($line in (Get-HostsLines)) {
            $data = ($line -split '#', 2)[0].Trim()

            if (-not $data) { continue }

            $parts = @($data -split '\s+')
            if ($parts.Count -lt 2) { continue }

            if ($parts[0] -notin @('127.0.0.1', '0.0.0.0')) {
                continue
            }

            foreach ($domain in $parts[1..($parts.Count - 1)]) {
                if ($domain -match '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$' -and
                    $domain -notin @('localhost')) {
                    $domain.ToLowerInvariant()
                }
            }
        }
    )

    @($found | Sort-Object -Unique)
}

# Back up before modifying the hosts file
function Save-HostsBackup {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $timestampBackup = "$hostsPath.$timestamp.bak"

    Copy-Item -LiteralPath $hostsPath -Destination $timestampBackup -ErrorAction Stop

    if (-not (Test-Path $backupPath)) {
        Copy-Item -LiteralPath $hostsPath -Destination $backupPath -ErrorAction Stop
    }

    Write-Host "Backup created: $timestampBackup" -ForegroundColor DarkGray
}

function Write-HostsFile {
    param([string[]]$Lines)

    Save-HostsBackup

    Set-Content -LiteralPath $hostsPath -Value $Lines -Encoding ascii -ErrorAction Stop

    ipconfig /flushdns | Out-Null
}

# Add a domain directly to the actual hosts file
function Add-Site {
    $site = (Read-Host "Enter domain (example.com, no https://)").Trim().ToLowerInvariant()

    if ($site -notmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') {
        Write-Host "Invalid domain format!" -ForegroundColor Red
        return
    }

    if (@(Get-Sites) -contains $site) {
        Write-Host "$site is already mapped to a blocking address." -ForegroundColor Yellow
        return
    }

    $lines = @(Get-HostsLines)
    $lines += "127.0.0.1`t$site`t# WBM"

    try {
        Write-HostsFile -Lines $lines
        Write-Host "Added to hosts file: $site" -ForegroundColor Green
    }
    catch {
        Write-Host "Could not update hosts file: $_" -ForegroundColor Red
    }
}

# Remove a selected domain while preserving other domains on its line
function Unblock-Site {
    $sites = @(Get-Sites)

    if ($sites.Count -eq 0) {
        Write-Host "No blocking entries found in the hosts file." -ForegroundColor Yellow
        return
    }

    Write-Host "`nSelect a domain to unblock:"
    for ($i = 0; $i -lt $sites.Count; $i++) {
        Write-Host "$($i + 1). $($sites[$i])"
    }

    Write-Host "0. Cancel"
    $choice = Read-Host "Enter number"

    if ($choice -notmatch '^\d+$') {
        Write-Host "Invalid selection." -ForegroundColor Red
        return
    }

    $number = [int]$choice
    if ($number -eq 0) { return }

    if ($number -lt 1 -or $number -gt $sites.Count) {
        Write-Host "Invalid selection." -ForegroundColor Red
        return
    }

    $selected = $sites[$number - 1]
    if ((Read-Host "Remove blocking entry for $selected? (Y/N)") -notmatch '^(?i)y$') {
        Write-Host "Cancelled."
        return
    }

    $newLines = @(
        foreach ($line in (Get-HostsLines)) {
            $split = $line -split '#', 2
            $data = $split[0].Trim()

            if (-not $data) {
                $line
                continue
            }

            $parts = @($data -split '\s+')

            if ($parts.Count -lt 2 -or
                $parts[0] -notin @('127.0.0.1', '0.0.0.0')) {
                $line
                continue
            }

            $domains = @($parts[1..($parts.Count - 1)])
            $remaining = @($domains | Where-Object {
                $_ -ine $selected
            })

            if ($remaining.Count -eq $domains.Count) {
                $line
                continue
            }

            if ($remaining.Count -gt 0) {
                $rebuilt = "$($parts[0])`t$($remaining -join ' ')"
                if ($split.Count -gt 1) {
                    $rebuilt += "`t# $($split[1].Trim())"
                }
                $rebuilt
            }
            # If no domains remain, omit this now-empty mapping line.
        }
    )

    try {
        Write-HostsFile -Lines $newLines
        Write-Host "Removed blocking entry: $selected" -ForegroundColor Green
    }
    catch {
        Write-Host "Could not update hosts file: $_" -ForegroundColor Red
    }
}

# Refresh means reread actual file and flush DNS.
# It does not restore an old saved list.
function Refresh-Hosts {
    try {
        $null = Get-HostsLines
        ipconfig /flushdns | Out-Null
        Write-Host "Read current hosts file and flushed DNS cache." -ForegroundColor Green
    }
    catch {
        Write-Host "Refresh failed: $_" -ForegroundColor Red
    }
}

# Main menu
$showBlockedSites = $false

while ($true) {
    Clear-Host

    try {
        $sites = @(Get-Sites)
    }
    catch {
        Write-Host "Unable to read hosts file: $_" -ForegroundColor Red
        Read-Host "Press Enter to exit"
        break
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "       WEBSITE BLOCKING MANAGER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " BLOCKED HOSTNAMES: $($sites.Count)" -ForegroundColor Yellow

    if ($showBlockedSites) {
        Write-Host "`n--- HOSTS FILE ENTRIES ---" -ForegroundColor Cyan

        if ($sites.Count -eq 0) {
            Write-Host "No blocking entries found." -ForegroundColor Gray
        }
        else {
            foreach ($site in $sites) {
                Write-Host " [BLOCKED] $site" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "`nWebsite list is hidden." -ForegroundColor Gray
    }

    Write-Host "`n----------------------------------------"
    Write-Host "1. Add a website"
    Write-Host "2. Unblock a website"
    Write-Host "3. Run / Refresh"
    Write-Host "4. Show / Hide blocked websites"
    Write-Host "5. Exit"
    Write-Host "----------------------------------------"

    $option = Read-Host "Choose an option (1-5)"

    switch ($option) {
        "1" {
            Add-Site
            Read-Host "Press Enter to return to menu"
        }
        "2" {
            Unblock-Site
            Read-Host "Press Enter to return to menu"
        }
        "3" {
            Refresh-Hosts
            Read-Host "Press Enter to return to menu"
        }
        "4" {
            $showBlockedSites = -not $showBlockedSites
        }
        "5" {
            break
        }
        default {
            Write-Host "Invalid option." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }

    if ($option -eq "5") { break }
}
