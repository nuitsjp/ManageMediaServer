netsh interface portproxy delete v4tov4 listenport=2283 listenaddress=0.0.0.0
Get-NetFirewallRule | Where-Object DisplayName -like "*Immich 2283*" | Remove-NetFirewallRule -Confirm:$false
wsl --unregister Ubuntu