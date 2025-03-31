param (
    [string]$Account = '',
    [string]$PAT = '',
    [int]$MonthsToLookBack = 1,
    [string]$BranchPatterns = 'refs/heads/(release|master|main)', 
    [string]$CommaSeperatedProjectsToScan = '*',
    [int]$MaxNumberOfRecentBuildsToLookBack = 100,
    [string]$OutputDirectory = "${PSScriptRoot}\BuildLogs"
)

$date = $((Get-Date).ToString('yyyy-MM-dd-HH-mm-ss'))
$dateToLookBack = $todaysDate.AddMonths($monthsToLookBack*-1)
# Create a web session
# Convert PAT to Base64 token
$token = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$($PAT)"))
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$session.Headers["Authorization"] = "Basic $token"
$session.Headers["Content-Type"] = "application/json"


# API URL to fetch all projects
if($CommaSeperatedProjectsToScan -eq '*') {
    $url = "https://dev.azure.com/$Account/_apis/projects?api-version=7.1-preview.4"
    $response = Invoke-RestMethod -Uri $url -Method Get -WebSession $session
    
    $Projects = $response.value | ForEach-Object { $_.name }
} else {
    $Projects = $CommaSeperatedProjectsToScan -split ',' | ForEach-Object { $_.Trim() }
}


foreach ($project in $Projects) {
    $url = "https://dev.azure.com/$Account/$project /_apis/pipelines?api-version=6.0-preview.1"
    $pipelines = Invoke-RestMethod -Uri $url -Method Get -WebSession $session

    foreach ($pipeline in $pipelines.value) {
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
        Write-Host "====================Get  $getBuildUrl  ============================="
        $builds = Invoke-RestMethod -Uri $getBuildUrl -Method Get -ContentType "application/json" -WebSession $session

        $branchHash = @{}
        $recentBuilds = $builds.value | Sort-Object -Property startTime -Descending | Select-Object -First $maxNumberOfRecentBuildsToLookBack
        foreach ($build in $recentBuilds) {
            $buildId = $build.id
            $branchName = $build.sourceBranch
            $buildDate = $build.startTime

            if ($build.status -ne 'completed' -or $build.result -ne 'succeeded') { 
                continue 
            } # Skip if the build is not completed or not succeeded.

            if($null -eq $buildDate)  { 
                continue 
            } # if build just started

            if( $buildDate -lt $dateToLookBack) { 
                break 
            } # No need to check for older recent builds.

            if($branchHash.ContainsKey($branchName) -or -not($branchName -match $branchPatterns)) {
                continue
            }
            else {
                $branchHash[$branchName] = $true
            }

            try {
                $BuildRun = "https://dev.azure.com/$Account/$project/_apis/build/builds/$buildId/timeline?api-version=7.1"
                Write-Host "====================Get  $BuildRun Details ============================="
                $BuildRundetails = Invoke-RestMethod -Uri $BuildRun -Method Get -ContentType "application/json" -WebSession $session
                $rs = $BuildRundetails.records | Where-Object { ($_.name -like "*build*" -or $_.name -like "*Python*") -and $_.type -eq 'Job' }

                if ($null -eq $rs -or $rs.Count -eq 0) { 
                    Write-Host "==================== Unable to get  build Records  for $BuildRun ============================="
                    continue 
                }
                $Repository = $build.repository.name
                $Branch = $build.sourceBranch
                $BuildDefination = $pipeline.name
                $BuildURL = $build._links.web.href
                $tempFolder = New-Item -Path ([System.IO.Path]::GetTempPath()) -Name "BuildJobTemp_$(Get-Random)" -ItemType Directory

                try {
                    foreach ($r in $rs) {
                        $BuildJobName = $r.name

                        if($null -eq $r.startTime -or $r.startTime -eq '') {
                            Write-Host "====================Unable to get  startTime BuildRun: $BuildRun, BuildJobName: $BuildJobName============================="
                            break
                        }

                        $startTime = [datetime]$r.startTime


                        if($null -eq $r.log -or $null -eq $r.log.url -or $r.log.url -eq '') {
                            continue
                        }

                        $LogsURL = $r.log.url
                        $buildresult = $r.result
                        
                        # Generate the log file name based on the build job name
                        $logFileName = "$($BuildJobName)_$($buildId)_$($date).log"
                        $artifactsTasklogFile = "$tempFolder\${logFileName}.txt"

                        Invoke-RestMethod -Uri $LogsURL -Method Get -ContentType "application/json" -WebSession $session | Out-File -FilePath $artifactsTasklogFile
                        $content = Get-Content -Raw -Path $artifactsTasklogFile

                        $pattern = '(?i)\\Python(\d+\.?\d*)\\python\.exe\b'
                        # Match patterns such as : Installing python v3.12.2"
                        $pattern1 = '(?i)Installing python v(\d+\.\d+\.\d+)'

                        $match = [regex]::Match($content, $pattern)
                        $match1 = [regex]::Match($content, $pattern1)
                        if ($match.Success -or $match1.Success) {
                            $patternPresentinBuild = $true
                            Write-Host "====================Python version found in BuildRun: $BuildRun, BuildJobName: $BuildJobName ============================="
                            if ($match1.Success) {
                                $fullVersion = $match1.Groups[1].Value

                            }
                            else {
                                $majorVersion = $match.Groups[1].Value
                                $minorVersion = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { "" }
                                $fullVersion = "$majorVersion$minorVersion"
                            }


                            Write-Output "Python Major Version: $majorVersion"
                            Write-Output "Python Minor Version: $minorVersion"
                            Write-Output "Full Python Version: $fullVersion"

                            $results = [PSCustomObject]@{
                                Organization = $Account
                                Project = $Project
                                Repository = $Repository
                                Branch = $Branch
                                Build = $buildresult
                                BuildDefination = $BuildDefination
                                BuildURL = $BuildURL
                                BuildJobName = $BuildJobName
                                StartTime = $startTime
                                LogsURL = $LogsURL
                                FullVersion = $fullVersion
                            }
                            $results | Export-Excel "${PSScriptRoot}\BuildLogs\$azureBuildJob_results_$($date).xlsx" -WorksheetName "BuildJob_Results" -TableName "BuildJob" -Append
                            $results | ConvertTo-CSV -Delimiter "," -NoTypeInformation | Select-Object -Last 1 | Out-File "${PSScriptRoot}\BuildLogs\azureBuildJob_results_$($date).csv" -Append
                            break
                        }
                    }
                }
                finally {
                    if (Test-Path $tempFolder) {
                        Remove-Item -Path $tempFolder -Recurse -Force -Verbose
                    }
                }
            }
            catch {
                Write-Host "Getting branches step threw error for this repo: $($_.Exception.Message) $($_.ScriptStackTrace)"
            }
        }
    }
}