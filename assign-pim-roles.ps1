<#
.SYNOPSIS
    A PowerShell script to create and update Azure RBAC assignments using PIM.

.DESCRIPTION
    This script takes input data from the input-pim-rbac.csv file and creates
    an Azure RBAC PIM assignment for each row of input data. If the input file
    is missing, it is created with examples. The examples show how the input
    fields can be specified.

.EXAMPLE
    PS C:\> .\assign-pim-roles.ps1

.NOTES
    Author:       Thajudheen T A
    Date:         October 2026
    Version:      1.0.0
    Changelog:
        - 1.0.0: Initial release.
.LINK
    https://github.com
#>

function Show-Options {
    param (
        $options
    )
    for ($i = 0; $i -lt $options.Length; $i++) {
        Write-Output "$($i + 1): $($options[$i])"
    }   
}

$ticketSystemName = "Azure" # replace this value as appropriate

Write-Output "Executing PIM RBAC Assignment Script."

$inputCsvFileName = "input-pim-rbac.csv"

Write-Output "Checking for input CSV file ..."

if (!(Test-Path -Path $inputCsvFileName)) {
    Write-Output "Input CSV file not found. Generating CSV file with examples..."

    New-Item -Force -ItemType File $inputCsvFileName | Out-Null
    Write-Output "# This CSV file provides the input data for the PIM role assignment script." > $inputCsvFileName
    Write-Output "# Fill in the data as per the examples provided below." >> $inputCsvFileName
    Write-Output "# Example 1: user-based active assignment" >> $inputCsvFileName
    Write-Output "# Example 2: group-based eligible time-bound assignment" >> $inputCsvFileName
    Write-Output "# Example 3: service-principal-based active assignment" >> $inputCsvFileName
    Write-Output "principal,principalType,scope,role,assignmentType,ticketNumber,duration" >> $inputCsvFileName
    Write-Output "user1,user,lab-network-identity,reader,active,TKT001" >> $inputCsvFileName
    Write-Output "test-group,group,lab-network,network contributor,eligible,TKT002,30" >> $inputCsvFileName
    Write-Output "test-sp,servicePrincipal,rg-lab-network,contributor,active,TKT002" >> $inputCsvFileName

    Write-Output "Exiting. Please review the CSV input file '$inputCsvFileName' for details."
    exit 0
}

Write-Output "
Refreshing Azure PowerShell token...
"

Get-AzAccessToken 3>&1 | Out-Null

if ($? -eq $false) {
    Write-Error "Cannot obtain valid access token for Azure PowerShell."
    Write-Error "Please review the previous error messages for the details."
    Write-Error "Exiting."
    exit 1
}

Write-Output "Processing input data from $inputCsvFileName"

Import-Csv $inputCsvFileName | ForEach-Object {

    $principal = $_.principal
    $principalType = $_.principalType
    $scope = $_.scope
    $role = $_.role
    $assignmentType = $_.assignmentType
    $ticketNumber = $_.ticketNumber
    $duration = $_.duration

    # reset variables
    $principalId = $null
    $scopeId = $null
    $roleDefinitionId = $null

    # Part 1: Principal identifier

    Write-Output ""
    Write-Output "Principal: $principal"
    Write-Output "Principal type: $principalType"

    if ($principalType -eq 'user') {
        Write-Output "Performing a user account search..."

        $filterQuery = "startsWith(UserPrincipalName,'" + $principal  `
        + "') or startsWith(Mail, '" + $principal  `
        + "') or startsWith(DisplayName, '" + $principal + "')"
        
        $queryResults = Get-AzADUser -Filter $filterQuery

        if ($queryResults.Length -eq 1) {
            Write-Output "User account found."
            $principalId = $queryResults.id
        } elseif ($queryResults.Length -gt 1) {
            Write-Output "Multiple user accounts found."
            $displayNames = @()
            $queryResults | ForEach-Object { $displayNames += $_.DisplayName }
            Show-Options $displayNames
            $userInput = Read-Host -Prompt "Enter selection"
            $principalId = ($queryResults[$($userInput - 1)]).id
        } else {
            Write-Error "User account not found in Entra ID."
            Write-Error "Skipping role assignment."
            return
        }

    } elseif ($principalType -eq 'group') {
        Write-Output "Performing a group search..."

        $filterQuery = "startsWith(DisplayName, '" + $principal + "')"

        $queryResults = Get-AzADGroup -Filter $filterQuery

        if ($queryResults.Length -eq 1) {
            Write-Output "Group found."
            $principalId = $queryResults.id
        } elseif ($queryResults.Length -gt 1) {
            Write-Output "Multiple groups found."
            $displayNames = @()
            $queryResults | ForEach-Object { $displayNames += $_.DisplayName }
            Show-Options $displayNames
            $userInput = Read-Host -Prompt "Enter selection"
            $principalId = ($queryResults[$($userInput - 1)]).id
        } else {
            Write-Error "Group not found in Entra ID."
            Write-Error "Skipping role assignment."
            return
        }

    } elseif ($principalType -eq 'servicePrincipal') {
        Write-Output "Performing a service principal search..."

        Write-Output "Checking if the input is a GUID ..."
        $outGuid = [guid]::Empty
        $result = [guid]::TryParse($principal, [ref]$outGuid)

        if ($result) {
            Write-Output "Input value is a GUID."
            $filterQuery = "(id eq '" + $principal + "') OR (appID eq '" + $principal + "')"
        } else {
            Write-Output "Input value is not a GUID."
            $filterQuery = "startsWith(DisplayName, '" + $principal + "')"
        }

        Write-Output "Searching ..."
        $queryResults = Get-AzADServicePrincipal -Filter $filterQuery

        if ($queryResults.Length -eq 1) {
            Write-Output "Service Principal found."
            $principalId = $queryResults.id
        } elseif ($queryResults.Length -gt 1) {
            Write-Output "Multiple service principals found."
            $displayNames = @()
            $queryResults | ForEach-Object { $displayNames += $_.DisplayName }
            Show-Options $displayNames
            $userInput = Read-Host -Prompt "Enter selection"
            $principalId = ($queryResults[$($userInput - 1)]).id
        } else {
            Write-Error "Service Principal not found in Entra ID."
            Write-Error "Skipping role assignment."
            return
        }

    } else {
        Write-Error "Invalid principal type."
        Write-Error "Skipping role assignment."
        return
    }

    Write-Output "Principal ID: $principalId"
    Write-Output ""

    # Part 2: Scope identifier

    Write-Output "Scope: $scope"
    
    Write-Output "Searching for a resource by exact name match..."
    $filterQuery = "resourcecontainers | union resources | where name == '" + $scope + "'"
    $queryResults = Search-AzGraph -Query $filterQuery

    if (@($queryResults).Length -eq 1) {
        Write-Output "Unique resource found."
        $scopeId = $queryResults.id
    } elseif (@($queryResults).Length -gt 1) {
        Write-Output "Multiple resources found."
        $scopeIds = @()
        $queryResults | ForEach-Object { $scopeIds += $_.id }
        Show-Options $scopeIds
        $userInput = Read-Host -Prompt "Enter selection"
        $scopeId = $scopeIds[$($userInput - 1)]
    } else {
        Write-Output "Exact match not found."
        Write-Output "Searching for an approximate match ..."
        $filterQuery = "resourcecontainers | union resources | where name contains '" + $scope + "'"
        $queryResults = Search-AzGraph -Query $filterQuery
        $scopeIds = @()
        $queryResults | ForEach-Object { $scopeIds += $_.id }

        if ($scopeIds.Length -eq 1){
            $scopeId = $scopeIds[0]
        } elseif ($scopeIds.Length -eq 0) {
            Write-Error "Resource not found."
            Write-Error "Skipping role assignment."
            return
        } elseif ($scopeIds.Length -gt 1) {
            Write-Output "Multiple resources found."
            Show-Options $scopeIds
            $userInput = Read-Host -Prompt "Enter selection"
            $scopeId = $scopeIds[$($userInput - 1)]
        }
    }

    Write-Output "Scope ID: $scopeId"
    Write-Output ""

    # Part 3: Role identifier

    Write-Output "Switching to the target subscription ..."
    $subId = ($scopeId -split "/")[2]
    Set-AzContext -Subscription $subId | Out-Null

    Write-Output "Searching for the role: $role"
    Write-Output "Searching for the role by exact name match ..."
    $roleSearchResults = Get-AzRoleDefinition 3>$null | Where-Object { $_.Name -eq $role }
    if ($roleSearchResults.Length -eq 1) {
        Write-Output "Unique role found."
        $roleDefGUID = $roleSearchResults.id
    }  else {
        Write-Output "Exact match not found."
        Write-Output "Searching for the role by approximate name match ..."
        $roleSearchResults = Get-AzRoleDefinition 3>$null | Where-Object { $_.Name -match $role }

        if ($roleSearchResults.Length -eq 1) {
            Write-Output "Unique role found."
            $roleDefGUID = $roleSearchResults.id
        } elseif ($roleSearchResults.Length -eq 0) {
            Write-Error "Role not found."
            Write-Error "Skipping role assignment."
            return
        } else {
            Write-Output "Multiple roles found."
            $roleNames = @()
            $roleSearchResults | ForEach-Object { $roleNames += $_.Name }
            Show-Options $roleNames
            $userInput = Read-Host -Prompt "Enter selection"
            $roleDefGUID = ($roleSearchResults[$($userInput - 1)]).id
        }
    }

    Write-Output "Role Definition GUID: $roleDefGUID"
    $roleDefinitionId = "/subscriptions/" + $subId + `
    "/providers/Microsoft.Authorization/roleDefinitions/" + $roleDefGUID
    Write-Output "Role Definition ID: $roleDefinitionId"
    Write-Output ""

    # Part 4: Validation

    if (!($principalId -and $scopeId -and $roleDefinitionId)) {
        Write-Error "One or more parameters are invalid and the assignment cannot proceed."
        Write-Error "Please check the previous error messages."
        return
    }

    if (($principalType -eq 'servicePrincipal') -and ($assignmentType -eq 'eligible')) {
        Write-Error "Service principals cannot have eligible role assignments. Skipping."
        return
    }

    if (($assignmentType -eq 'active') -and !($ticketNumber)) {
        Write-Error "Active role assignments need a justification to be provided by the admin."
        Write-Error "Please ensure that the ticketNumber column is included."
        return
    }

    # Part 5: Additional info

    
    $assignmentName = (New-Guid).ToString()

    $currentDate = Get-Date
    $startTimestamp = $currentDate.ToString("O") # assignment takes effect immediately

    if ($duration) {
        # duration value is specified
        if($duration -eq 'permanent') {
            # duration is specified as 'permanent'
            $assignmentType = $assignmentType + $duration
        } else {
            # duration is specified as N number of days
            $endDate = $currentDate.AddDays($duration)
            $endTimestamp = (Get-Date -Year $endDate.Year -Month $endDate.Month -Day $endDate.Day `
            -Hour 1 -Minute 0 -Second 0 -Millisecond 0).ToString("O")
        }
    } else {
        # duration is not specified
        $duration = 180 # default value of 180 days
        $endDate = $currentDate.AddDays($duration)
        $endTimestamp = (Get-Date -Year $endDate.Year -Month $endDate.Month -Day $endDate.Day `
        -Hour 1 -Minute 0 -Second 0 -Millisecond 0).ToString("O")
    }

    if ($assignmentType -eq 'active') {

        Write-Output "Creating active role assignment ..."

        New-AzRoleAssignmentScheduleRequest `
        -Name $assignmentName `
        -Scope $scopeId `
        -ExpirationType "AfterDateTime" `
        -ExpirationEndDateTime $endTimestamp `
        -ScheduleInfoStartDateTime $startTimestamp `
        -Justification $ticketNumber `
        -PrincipalId $principalId `
        -RequestType "AdminUpdate" `
        -RoleDefinitionId $roleDefinitionId `
        -TicketSystem $ticketSystemName `
        -TicketNumber $ticketNumber | Format-List

        if ($? -eq $false) {
            Write-Output ""
            Write-Error "PIM cmdlet has failed to create the assignment."
            Write-Error "Please review the previous error messages for the details."
        }

    } elseif ($assignmentType -eq 'eligible') {

        Write-Output "Creating eligible role assignment ..."

        New-AzRoleEligibilityScheduleRequest `
        -Name $assignmentName `
        -Scope $scopeId `
        -ExpirationType "AfterDateTime" `
        -ExpirationEndDateTime $endTimestamp `
        -ScheduleInfoStartDateTime $startTimestamp `
        -PrincipalId $principalId `
        -RequestType "AdminUpdate" `
        -RoleDefinitionId $roleDefinitionId `
        -TicketSystem $ticketSystemName `
        -TicketNumber $ticketNumber | Format-List

        if ($? -eq $false) {
            Write-Output ""
            Write-Error "PIM cmdlet has failed to create the assignment."
            Write-Error "Please review the previous error messages for the details."
        }

    } elseif ($assignmentType -eq 'activePermanent') { 
        
        Write-Output "Creating active permanent role assignment ..."

        New-AzRoleAssignmentScheduleRequest `
        -Name $assignmentName `
        -Scope $scopeId `
        -ExpirationType "NoExpiration" `
        -ScheduleInfoStartDateTime $startTimestamp `
        -Justification $ticketNumber `
        -PrincipalId $principalId `
        -RequestType "AdminUpdate" `
        -RoleDefinitionId $roleDefinitionId `
        -TicketSystem $ticketSystemName `
        -TicketNumber $ticketNumber | Format-List

        if ($? -eq $false) {
            Write-Output ""
            Write-Warning "PIM cmdlet has failed; falling back to Azure RBAC cmdlet..."

            New-AzRoleAssignment `
            -ObjectId $principalId `
            -RoleDefinitionId $roleDefGUID `
            -Scope $scopeId `
            -Description $ticketNumber | Format-List

            if ($? -eq $false) {
                Write-Output ""
                Write-Error "Azure RBAC cmdlet has failed to create the assignment."
                Write-Error "Please review the previous error messages for the details."
            }
        }

    } elseif ($assignmentType -eq 'eligiblePermanent') { 
        
        Write-Output "Creating eligible permanent role assignment ..."

        New-AzRoleEligibilityScheduleRequest `
        -Name $assignmentName `
        -Scope $scopeId `
        -ExpirationType "NoExpiration" `
        -ScheduleInfoStartDateTime $startTimestamp `
        -PrincipalId $principalId `
        -RequestType "AdminUpdate" `
        -RoleDefinitionId $roleDefinitionId `
        -TicketSystem $ticketSystemName `
        -TicketNumber $ticketNumber | Format-List

        if ($? -eq $false) {
            Write-Output ""
            Write-Error "PIM cmdlet has failed to create the assignment."
            Write-Error "Please review the previous error messages for the details."
        }
        
    } else {
        Write-Error "Invalid role assignment type provided. Skipping assignment."
        return
    }

    Start-Sleep -Seconds 1

}

Write-Output ""
Write-Output "PIM RBAC Assignment script execution completed."
