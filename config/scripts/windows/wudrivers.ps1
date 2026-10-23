# Windows > Updates: driver updates offered by Windows Update. Keep this file ASCII-only.
Write-Step 'Searching Windows Update for driver updates'
$found = Find-TTUpdates 'Driver'
Write-Step 'Downloading drivers'
Save-TTUpdates $found
Write-Step 'Installing drivers'
Install-TTUpdates $found
