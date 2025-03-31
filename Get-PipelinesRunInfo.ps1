
param (
    [string]$Account = '',
    [string]$PAT = '',
    [int]$MonthsToLookBack = 3,
    [string]$ProjectsToScan = '',
    [string]$BranchPatterns = 'refs/heads/(release|main)', # respects master, main, product, release, dev
    [int]$MaxNumberOfRecentBuildsToLookBack = 10000,
    [string]$OutputDirectory = "${PSScriptRoot}\BuildLogs"
)

$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($PAT)"))
$date = $((Get-Date).ToString('yyyy-MM-dd-HH-mm-ss'))
$dateToLookBack = $todaysDate.AddMonths($monthsToLookBack*-1)


# Create a web session
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$session.Headers["Authorization"] = "Basic $token"
$session.Headers["Content-Type"] = "application/json"

# API URL to fetch all projects
if($ProjectsToScan -eq '*') {
    $url = "https://dev.azure.com/$Account/_apis/projects?api-version=7.1-preview.4"
    $response = Invoke-RestMethod -Uri $url -Method Get -WebSession $session
    
    $Projects = $response.value | ForEach-Object { $_.name }
} else {
    $Projects = $ProjectsToScan -split ',' | ForEach-Object { $_.Trim() }
}

foreach ($project in $Projects) 
{

    $url = "https://dev.azure.com/$Account/$project/_apis/pipelines?api-version=6.0-preview.1"
    $pipelines = Invoke-RestMethod -Uri $url -Method Get -WebSession $session
    
    foreach ($pipeline in $pipelines.value) 
    {
        $results = @()

        $pipeineId = $pipeline.id
        # API URL to fetch the pipeline definition
        $pipelineUrl = "https://dev.azure.com/$Account/$Project/_apis/build/definitions/${pipeineId}?api-version=6.0"

        # Fetch the current pipeline definition
        $pipelineDetails  = Invoke-RestMethod -Uri $pipelineUrl -Method Get -WebSession $session -ErrorAction Stop

        if ($null -eq $pipelineDetails ) {
            Write-Host "Failed to fetch pipeline definition! $($pipeline.name)"
            continue
        }

        # Check if the pipeline is enabled
        if ($pipelineDetails.queueStatus -eq "disabled") {
            continue
        }

        Write-Host "====================  $($pipeline.name)  ============================="

        $getBuildUrl = "https://dev.azure.com/$Account/$project/_apis/build/builds?definitions=$($pipelineDetails.id)&api-version=6.0"
        $builds = Invoke-RestMethod -Uri $getBuildUrl -Method Get -ContentType "application/json" -WebSession $session
        $recentBuilds = $builds.value | Sort-Object -Property startTime -Descending | Select-Object -First $maxNumberOfRecentBuildsToLookBack

        foreach ($build in $recentBuilds) 
        {
            $buildId = $build.id
            $branchName = $build.sourceBranch
            $buildDate = $build.startTime
            $buildReason = $build.reason
            $buildResult = $build.result

            if ($build.status -ne 'completed' ) { 
                continue 
            } # Skip if the build is not completed or not succeeded.

            if($null -eq $buildDate -and $buildDate -lt $dateToLookBack) {
                continue 
            }

            try {
                $Repository = $build.repository.name
                $Branch = $branchName
                $BuildDefinition = $pipeline.name
                $BuildURL = $build._links.web.href
                $BuildActualUrl = $BuildUrl.Replace("https://dev.azure.com/$Account/$Project/_apis/build/builds/", "https://dev.azure.com/$Account/$Project/_build/results?buildId=")

                try {
                    if ($buildResult -eq 'succeeded') {
                        $result = [PSCustomObject]@{
                            Organization = $Account
                            Project = $Project
                            Repository = $Repository                            
                            Branch = $Branch
                            BuildId = $buildId
                            PipelineId = $pipeineId
                            Build = $buildresult
                            BuildDefinition = $BuildDefinition
                            BuildURL = $BuildActualUrl
                            BuildDate = $buildDate
                            BuildReason = $buildReason
                            JobName = ""
                            JobStartTime = ""
                            JobLogsURL = ""
                            JobResult = ""
                        }
                    }
                    else 
                    {
                        $BuildRun = "https://dev.azure.com/$Account/$project/_apis/build/builds/$buildId/timeline?api-version=7.1"
                        $BuildRundetails = Invoke-RestMethod -Uri $BuildRun -Method Get -WebSession $session
                        $r = $BuildRundetails.records | Where-Object { $null -ne $_.result -and $_.result -eq 'failed' -and $_.type -eq 'Job' } | Select-Object -First 1

                        $JobName = $r.name
                        $JobStartTime = ""
                        $JobLogsURL = ""
                        $jobResult = ""

                        if(-not($null -eq $r.startTime -or $r.startTime -eq '')) {
                            $JobStartTime = $r.startTime
                        }

                        if(-not($null -eq $r.log -or $null -eq $r.log.url -or $r.log.url -eq '')) {
                            $JobLogsURL = $r.log.url
                            $jobResult = $r.result
                        }

                        $result = [PSCustomObject]@{
                            Organization = $Account
                            Project = $Project
                            Repository = $Repository
                            Branch= $Branch
                            BuildId = $buildId
                            PipelineId = $pipeineId
                            Build = $buildresult
                            BuildDefinition = $BuildDefinition
                            BuildURL = $BuildActualUrl
                            BuildDate = $buildDate
                            BuildReason = $buildReason
                            JobName = $JobName
                            JobStartTime = $JobStartTime
                            JobLogsURL = $JobLogsURL
                            JobResult = $jobResult
                        }
                    }

                    $results += $result
                }
                catch {
                    Write-Host "New errors reported 1: $($_.Exception.Message) $($_.ScriptStackTrace)"
                }
            }
            catch {
                Write-Host "New errors reported 2: $($_.Exception.Message) $($_.ScriptStackTrace)"
            }
        }
        if($results.Count -ne 0) {
            Write-Host "Total builds found for $($pipeline.name) : $($results.Count)"
            $results | Export-Excel "${PSScriptRoot}\BuildLogs\$azureBuildJob_results_$($date).xlsx" -WorksheetName "BuildJob_Results" -TableName "BuildJob" -Append
            $results | ConvertTo-CSV -Delimiter "," -NoTypeInformation | Select-Object -Last 1 | Out-File "${PSScriptRoot}\BuildLogs\azureBuildJob_results_$($date).csv" -Append
        }
    }
}
