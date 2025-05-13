param (
    [string]$Account = 'YourOrgName',  # <-- Replace with your Azure DevOps organization name
    [string]$Token = '',
    [int]$daysToLookback = 15,
    [string]$BranchPatterns = 'refs/heads/(release|product|master|main|develop|osmain)',
    [string]$ProjectsToScan = '*',
    [int]$MaxNumberOfRecentBuildsToLookBack = 100,
    [string]$OutputDirectory = "${PSScriptRoot}\BuildLogs"
)

Write-Host "Account: $Account"
Write-Host "BranchPatterns: $BranchPatterns"
Write-Host "ProjectsToScan: $ProjectsToScan"
Write-Host "MaxNumberOfRecentBuildsToLookBack: $MaxNumberOfRecentBuildsToLookBack"
Write-Host "OutputDirectory: $OutputDirectory"
Write-Host "DaysToLookback: $daysToLookback"

$PAT = ""

if (-not $Token -and -not $PAT) {
    throw "Either a Token or PAT must be provided."
}

$date = (Get-Date).ToString('yyyy-MM-dd-HH-mm-ss')
$dateToLookBack = (Get-Date).AddDays($daysToLookback * -1)
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

if ($Token) {
    $session.Headers["Authorization"] = "Bearer $Token"
} elseif ($PAT) {
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
    $session.Headers["Authorization"] = "Basic $base64AuthInfo"
}
$session.Headers["Content-Type"] = "application/json"

# Get project list
if ($ProjectsToScan -eq '*') {
    $url = "https://dev.azure.com/$Account/_apis/projects?api-version=7.1-preview.4"
    $response = Invoke-AdoRequest -Uri $url -Method Get -WebSession $session
    $Projects = $response.value | ForEach-Object { $_.name }
} else {
    $Projects = $ProjectsToScan -split ',' | ForEach-Object { $_.Trim() }
}

foreach ($project in $Projects) {
    $url = "https://dev.azure.com/$Account/$project/_apis/pipelines?api-version=6.0-preview.1"
    $pipelines = Invoke-AdoRequest -Uri $url -Method Get -WebSession $session

    foreach ($pipeline in $pipelines.value) {
        $pipelineId = $pipeline.id
        $pipelineUrl = "https://dev.azure.com/$Account/$project/_apis/build/definitions/$pipelineId?api-version=6.0"
        $pipelineDetails = Invoke-AdoRequest -Uri $pipelineUrl -Method Get -WebSession $session -ErrorAction Stop

        if ($null -eq $pipelineDetails) {
            Write-Host "Failed to fetch pipeline definition! $($pipeline.name)"
            continue
        }

        if ($pipelineDetails.queueStatus -eq "disabled") { continue }

        $getBuildUrl = "https://dev.azure.com/$Account/$project/_apis/build/builds?definitions=$($pipelineDetails.id)&api-version=6.0"
        $builds = Invoke-AdoRequest -Uri $getBuildUrl -Method Get -ContentType "application/json" -WebSession $session

        $branchHash = @{}
        $recentBuilds = $builds.value | Sort-Object -Property startTime -Descending | Select-Object -First $MaxNumberOfRecentBuildsToLookBack

        foreach ($build in $recentBuilds) {
            $buildId = $build.id
            $branchName = $build.sourceBranch
            $buildDate = $build.startTime

            if ($build.status -ne 'completed' -or $build.result -ne 'succeeded') { continue }
            if ($null -eq $buildDate -or $buildDate -lt $dateToLookBack) { continue }
            if ($branchHash.ContainsKey($branchName) -or -not ($branchName -match $BranchPatterns)) { continue }

            $branchHash[$branchName] = $true

            try {
                $BuildRun = "https://dev.azure.com/$Account/$project/_apis/build/builds/$buildId/timeline?api-version=7.1"
                $BuildRunDetails = Invoke-AdoRequest -Uri $BuildRun -Method Get -ContentType "application/json" -WebSession $session
                $rs = $BuildRunDetails.records | Where-Object { ($_.name -like "*build*" -or $_.name -like "*Python*") -and $_.type -eq 'Job' }

                if ($null -eq $rs -or $rs.Count -eq 0) { continue }

                $Repository = $build.repository.name
                $Branch = $build.sourceBranch
                $BuildDefination = $pipeline.name
                $BuildURL = $build._links.web.href
                $tempFolder = New-Item -Path ([System.IO.Path]::GetTempPath()) -Name "BuildJobTemp_$(Get-Random)" -ItemType Directory

                try {
                    foreach ($r in $rs) {
                        $BuildJobName = $r.name
                        if (-not $r.startTime) { break }
                        $startTime = [datetime]$r.startTime

                        if (-not $r.log?.url) { continue }

                        $LogsURL = $r.log.url
                        $buildresult = $r.result
                        $logFileName = "$($BuildJobName)_$($buildId)_$($date).log"
                        $artifactsTasklogFile = "$tempFolder\${logFileName}.txt"

                        Invoke-AdoRequest -Uri $LogsURL -Method Get -ContentType "application/json" -WebSession $session | Out-File -FilePath $artifactsTasklogFile
                        $content = Get-Content -Raw -Path $artifactsTasklogFile

                        $pattern = '(?i)\\Python(\d+\.?\d*)\\python\.exe\b'
                        $pattern1 = '(?i)Installing python v(\d+\.\d+\.\d+)'

                        $match = [regex]::Match($content, $pattern)
                        $match1 = [regex]::Match($content, $pattern1)

                        if ($match.Success -or $match1.Success) {
                            if ($match1.Success) {
                                $fullVersion = $match1.Groups[1].Value
                            } else {
                                $majorVersion = $match.Groups[1].Value
                                $minorVersion = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { "" }
                                $fullVersion = "$majorVersion$minorVersion"
                            }

                            $results = [PSCustomObject]@{
                                Organization     = $Account
                                Project          = $project
                                Repository       = $Repository
                                Branch           = $Branch
                                Build            = $buildresult
                                BuildDefination  = $BuildDefination
                                BuildURL         = $BuildURL
                                BuildJobName     = $BuildJobName
                                StartTime        = $startTime
                                LogsURL          = $LogsURL
                                FullVersion      = $fullVersion
                            }

                            $ActualProjectsToScan = $ProjectsToScan.Replace("*", "")
                            $results | ConvertTo-Csv -Delimiter "," -NoTypeInformation | Select-Object -Last 1 | Out-File "$OutputDirectory\ADOReport_${ActualProjectsToScan}_$($date).csv" -Append

                            # Optional Excel export if module is available
                            # $results | Export-Excel "$OutputDirectory\ADOReport_${ActualProjectsToScan}_$($date).xlsx" -WorksheetName "BuildJob_Results" -TableName "BuildJob" -Append
                            break
                        }
                    }
                } finally {
                    if (Test-Path $tempFolder) {
                        Remove-Item -Path $tempFolder -Recurse -Force -Verbose
                    }
                }
            } catch {
                Write-Host "Error fetching branches: $($_.Exception.Message)"
            }
        }
    }
}
