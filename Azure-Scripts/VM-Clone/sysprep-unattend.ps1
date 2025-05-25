Invoke-WebRequest -Uri 'https://babvdivmbootdiag01.blob.core.windows.net/sysprep/unattend.xml' -OutFile 'C:\unattend.xml'
Start-Process -FilePath 'C:\Windows\System32\Sysprep\Sysprep.exe' -ArgumentList '/generalize /oobe /shutdown /unattend:C:\unattend.xml /quiet' -Wait
