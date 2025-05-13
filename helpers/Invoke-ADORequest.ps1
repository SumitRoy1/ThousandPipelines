function Invoke-ADORequest {
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateSet("Get", "Post", "Put", "Delete", "Patch")]
        [string]$Method = "Get",

        [object]$Body = $null,

        [Parameter(Mandatory)]
        [Microsoft.PowerShell.Commands.WebRequestSession]$WebSession,

        [string]$ContentType = "application/json"
    )

    $maxAttempts = 2
    $attempt = 1

    while ($attempt -le $maxAttempts) {
        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                WebSession  = $WebSession
                ContentType = $ContentType
            }

            if ($Body -ne $null -and $Method -in @("Post", "Put", "Patch")) {
                $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 }
            }

            return Invoke-RestMethod @params
        } catch {
            Write-Warning "Attempt $attempt failed for request."
            Write-Warning "Reason: $($_.Exception.Message)"

            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 60
            }
        }

        $attempt++
    }

    Write-Error "Request to '$Uri' failed after $maxAttempts attempts."
    return $null
}
