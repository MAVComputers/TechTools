# MouthWatch IOC (Dental > 3rd Party Apps): download the installer from
# mouthwatch.com, check its signature and start it. Keep this file ASCII-only.

Write-Step 'Downloading the MouthWatch installer'
$exe = Save-TTDownload -Url 'https://mouthwatch.com/wp-content/uploads/downloads/setupmouthwatch.exe' -Name 'setupmouthwatch.exe'

Write-Step 'Checking the digital signature'
Assert-TTSignature $exe

Write-Step 'Starting the installer'
Start-TTInstaller $exe
