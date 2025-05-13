<#
.SYNOPSIS
Fetches and analyzes recent Azure DevOps build data for specified projects.

.NOTES
- Ensure token or PAT is securely provided via parameters or environment variables.
- Avoid hardcoding sensitive credentials.
#>

param (
    [string]$Account = 'YourOrganizationName',
    [string]$Token = '',
    [int]$DaysToLookback = 10,
    [string]$ProjectsToScan = 'ProjectA,ProjectB', # Comma-separated list
    [string]$BranchPatterns = 'refs/heads/(release|product|master|main|develop|osmain)',
    [int]$MaxNumberOfRecentBuildsToLookBack = 5000,
    [string]$OutputDirectory = "${PSScriptRoot}\BuildLogs"
)

Write-Host "Account: $Account"
Write-Host "BranchPatterns: $BranchPatterns"
Write-Host "ProjectsToScan: $ProjectsToScan"
Write-Host "MaxNumberOfRecentBuildsToLookBack: $MaxNumberOfRecentBuildsToLookBack"
Write-Host "OutputDirectory: $OutputDirectory"
Write-Host "DaysToLookback: $DaysToLookback"

$PAT = ""  # Securely retrieve this from environment or key vault if needed

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

if ($Token) {
    $session.Headers["Authorization"] = "Bearer $Token"
} elseif ($PAT) {
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
    $session.Headers["Authorization"] = "Basic $base64AuthInfo"
}

$session.Headers["Content-Type"] = "application/json"

$date = (Get-Date).ToString('yyyy-MM-dd-HH-mm-ss')
$dateToLookBack = (Get-Date).AddDays(-1 * $DaysToLookback)

if ($ProjectsToScan -eq '*') {
    $url = "https://dev.azure.com/$Account/_apis/projects?api-version=7.1-preview.4"
    $response = Invoke-ADORequest -Uri $url -Method Get -WebSession $session
    $Projects = $response.value | ForEach-Object { $_.name }
} else {
    $Projects = $ProjectsToScan -split ',' | ForEach-Object { $_.Trim() }
}

$results = @()

foreach ($project in $Projects) {
    Write-Host "Fetching builds for project: $project"
    $minTime = $dateToLookBack.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Host "Using minTime: $minTime"

    $buildsUrl = "https://dev.azure.com/$Account/$project/_apis/build/builds?`$top=${MaxNumberOfRecentBuildsToLookBack}&statusFilter=completed&minTime=$minTime&api-version=6.0"
    $buildsResponse = Invoke-ADORequest -Uri $buildsUrl -Method Get -WebSession $session -ErrorAction Stop
    $recentBuilds = $buildsResponse.value | Sort-Object -Property startTime -Descending | Select-Object -First $MaxNumberOfRecentBuildsToLookBack

    Write-Host "Fetched $($recentBuilds.Count) recent builds for $project"

    foreach ($build in $recentBuilds) {
        if ($build.status -ne 'completed') { continue }
        $buildDate = $build.startTime
        if (-not $buildDate -or $buildDate -lt $dateToLookBack) { continue }
        $branchName = $build.sourceBranch
        if (-not ($branchName -match $BranchPatterns)) { continue }

        $buildResult = $build.result
        $pipelineId = $build.definition.id
        $pipelineName = $build.definition.name
        $buildId = $build.id
        $buildReason = $build.reason
        $repository = $build.repository.name
        $buildUrl = $build._links.web.href
        $buildActualUrl = $buildUrl.Replace("https://dev.azure.com/$Account/$project/_apis/build/builds/", "https://dev.azure.com/$Account/$project/_build/results?buildId=")

        Write-Host "Processing build $buildId from $branchName on $buildDate ($buildResult)"

        try {
            if ($buildResult -eq 'succeeded') {
                $result = [PSCustomObject]@{
                    Organization    = $Account
                    Project         = $project
                    Repository      = $repository
                    Branch          = $branchName
                    BuildId         = $buildId
                    PipelineId      = $pipelineId
                    Build           = $buildResult
                    BuildDefinition = $pipelineName
                    BuildURL        = $buildActualUrl
                    BuildDate       = $buildDate
                    BuildReason     = $buildReason
                    JobName         = ""
                    JobStartTime    = ""
                    JobLogsURL      = ""
                    JobResult       = ""
                    JobMessage      = ""
                }
            } else {
                # Timeline logic...
                $timelineUrl = "https://dev.azure.com/$Account/$project/_apis/build/builds/$buildId/timeline?api-version=7.1"
                $timeline = Invoke-ADORequest -Uri $timelineUrl -Method Get -WebSession $session -ErrorAction Stop

                function Get-AncestorStage {
                    param ([object]$record, [array]$allRecords)
                    $current = $record
                    while ($current -and $current.parentId) {
                        $parent = $allRecords | Where-Object { $_.id -eq $current.parentId }
                        if ($parent -and $parent.type -eq 'Stage') {
                            return $parent
                        }
                        $current = $parent
                    }
                    return $null
                }

                $failedTasks = $timeline.records | Where-Object { $_.type -eq 'Task' -and $_.result -eq 'failed' }
                $failedJobs = $timeline.records | Where-Object { $_.type -eq 'Job' -and $_.result -eq 'failed' }

                $message = ""
                $firstFailedJobWithMessage = $null

                foreach ($task in $failedTasks) {
                    $job = $failedJobs | Where-Object { $_.id -eq $task.parentId }
                    if (-not $job) { continue }

                    $stage = Get-AncestorStage -record $job -allRecords $timeline.records
                    if (-not $stage -or $stage.result -ne 'failed') { continue }

                    if ($task.issues) {
                        $message = "Failed Task: $($task.name)`n"
                        $task.issues | Select-Object -First 10 | ForEach-Object {
                            $message += " - [$($_.type)] $($_.message)`n"
                        }
                    }

                    $firstFailedJobWithMessage = $job
                    break
                }

                $JobName = $firstFailedJobWithMessage.name
                $JobStartTime = $firstFailedJobWithMessage.startTime
                $JobLogsURL = $firstFailedJobWithMessage.log?.url
                $JobResult = $firstFailedJobWithMessage.result

                $result = [PSCustomObject]@{
                    Organization    = $Account
                    Project         = $project
                    Repository      = $repository
                    Branch          = $branchName
                    BuildId         = $buildId
                    PipelineId      = $pipelineId
                    Build           = $buildResult
                    BuildDefinition = $pipelineName
                    BuildURL        = $buildActualUrl
                    BuildDate       = $buildDate
                    BuildReason     = $buildReason
                    JobName         = $JobName
                    JobStartTime    = $JobStartTime
                    JobLogsURL      = $JobLogsURL
                    JobResult       = $JobResult
                    JobMessage      = $message
                }
            }

            $results += $result
            Write-Host "$buildDate | $buildResult | $pipelineName | $branchName | $JobName"
        } catch {
            Write-Host "Error processing build $buildId: $($_.Exception.Message)"
        }
    }

    $ActualProjectsToScan = if ($ProjectsToScan -eq '*') { 'all' } else { $ProjectsToScan.Replace(",", "_") }

    if ($results.Count -ne 0) {
        Write-Host "Total builds found for project $project: $($results.Count)"
        $results | Export-Excel "$OutputDirectory\ADOReport_${ActualProjectsToScan}_$date.xlsx" -WorksheetName "BuildJob_Results" -TableName "BuildJob" -Append
        $results | ConvertTo-Csv -Delimiter "," -NoTypeInformation | Select-Object -Last 1 | Out-File "$OutputDirectory\ADOReport_${ActualProjectsToScan}_$date.csv" -Append
    } else {
        Write-Host "No builds found for project $project."
    }
}
