# Windows > Updates: search, download and install Windows updates (no drivers).
# The restart is left to the tech. Keep this file ASCII-only.
Write-Step 'Searching Windows Update (can take a few minutes)'
$found = Find-TTUpdates 'Software'
Write-Step 'Downloading updates'
Save-TTUpdates $found
Write-Step 'Installing updates'
Install-TTUpdates $found
