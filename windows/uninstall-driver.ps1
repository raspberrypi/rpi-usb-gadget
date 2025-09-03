param(
  [string]$InfName = "raspberrypi-rndis.inf",
  [string]$Provider = "Raspberry Pi Ltd."
)

# Find published driver package names (oemNNN.inf) for our INF or provider in the Net class
$pubs = @()
$block = @{}

# Use /class Net to narrow output; robust across x64/ARM64
$lines = & $env:SystemRoot\System32\pnputil.exe /enum-drivers /class Net 2>$null

foreach ($line in $lines) {
  if ($line -match 'Published Name\s*:\s*(oem\d+\.inf)') { $block.Pub = $matches[1] }
  elseif ($line -match 'Original Name\s*:\s*(.+\.inf)') { $block.Orig = $matches[1].Trim() }
  elseif ($line -match 'Provider\s*:\s*(.+)')           { $block.Prov = $matches[1].Trim() }
  elseif ($line.Trim() -eq '') {
    if ($block.Pub -and ( ($block.Orig -ieq $InfName) -or ($block.Prov -ieq $Provider) )) {
      $pubs += $block.Pub
    }
    $block = @{}
  }
}
# Catch last block if file didn't end with a blank line
if ($block.Pub -and ( ($block.Orig -ieq $InfName) -or ($block.Prov -ieq $Provider) )) { $pubs += $block.Pub }

$pubs = $pubs | Sort-Object -Unique
foreach ($p in $pubs) {
  try {
    Start-Process -FilePath "$env:SystemRoot\System32\pnputil.exe" -ArgumentList "/delete-driver $p /uninstall /force" -Wait -NoNewWindow
  } catch {
    # Best-effort uninstall
  }
}
