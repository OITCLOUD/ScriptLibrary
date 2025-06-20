##########################
# Define Script variables#
##########################
$EveningLimit = "21:00"
#$EveningLimit = Ninja-Property-Get eveningLimit
$MorningLimit = "09:30"
#$MorningLimit = Ninja-Property-Get morningLimit
$LoggedInUser = "<username>" # This should be replaced with the actual logged-in user, e.g., $env:USERNAME or use 'AZUREAD\$env:USERNAME' for Azure AD users
# $LoggedInUser = Ninja-Property-Get loggedInUser
$DenyGroup = "Guests" # This should be the group you want to add the user to when they are outside the allowed time range, e.g., "Guests" or a custom group

##########################
# Computing Script Input #
##########################
$EveningTargetTime = [datetime]::ParseExact($EveningLimit, "HH:mm", $null)
$MorningTargetTime = [datetime]::ParseExact($MorningLimit, "HH:mm", $null)

# Get the current time
$currentTime = Get-Date

####################
# Script Execution #
####################

If ($currentTime.TimeOfDay -gt $EveningTargetTime.TimeOfDay) {
  Add-LocalGroupMember -Group $DenyGroup -Member $LoggedInUser
  Write-Output "Time is within the Evening limit"
  #Invoke-Expression "tsdiscon"
  Invoke-Expression 'shutdown /s /t 180 /c "The Computer will be shutdown in 3 minutes. Save your work!"'
  }
  
If ($currentTime.TimeOfDay -lt $MorningTargetTime.TimeOfDay) {
  Add-LocalGroupMember -Group $DenyGroup -Member $LoggedInUser
  Write-Output "Time is within the Morning limit"
  #Invoke-Expression "Logoff"
  Invoke-Expression 'shutdown /s /t 180 /c "The Computer will be shutdown in 3 minutes. Save your work!"'
  }
  
If (($currentTime.TimeOfDay -gt $MorningTargetTime.TimeOfDay) -and ($currentTime.TimeOfDay -lt $EveningTargetTime.TimeOfDay) ) {
  Write-Output "All is OK"
}