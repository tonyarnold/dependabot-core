Set-StrictMode -version 2.0
$ErrorActionPreference = "Stop"

$jobString = Get-Content -Path $env:DEPENDABOT_JOB_PATH
$job = (ConvertFrom-Json -InputObject $jobString).job

function Get-Files {
    Write-Host "Job: $($job | ConvertTo-Json)"
    $sourceRepo = $job.source.repo
    # TODO: handle other values from $job.source.provider
    $url = "https://github.com/$sourceRepo"
    $branchArgs = ""
    if ("branch" -in $job.source.Psobject.Properties.Name) {
        $branchArgs = "--branch $($job.source.branch)"
    }

    Invoke-Expression "git clone --recurse-submodule $branchArgs $url $env:DEPENDABOT_REPO_CONTENTS_PATH"
    if ("commit" -in $job.source.PSobject.Properties.Name) {
        git fetch origin
        git checkout $job.source.commit
    }
}

function Install-Sdks([string] $directory) {
    $installedSdks = dotnet --list-sdks | ForEach-Object { $_.Split(' ')[0] }
    if ($installedSdks.GetType().Name -eq "String") {
        # if only a single value was returned (expected in the container), then force it to an array
        $installedSdks = @($installedSdks)
    }
    Write-Host "Currently installed SDKs: $installedSdks"
    $rootDir = Convert-Path $env:DEPENDABOT_REPO_CONTENTS_PATH
    $candidateDir = Convert-Path "$rootDir/$directory"
    while ($true) {
        $globalJsonPath = Join-Path $candidateDir "global.json"
        if (Test-Path $globalJsonPath) {
            $globalJson = Get-Content $globalJsonPath | ConvertFrom-Json
            $sdkVersion = $globalJson.sdk.version
            if (-Not ($sdkVersion -in $installedSdks)) {
                $installedSdks += $sdkVersion
                Write-Host "Installing SDK $sdkVersion as specified in $globalJsonPath"
                & $env:DOTNET_INSTALL_SCRIPT_PATH --version $sdkVersion --install-dir $env:DOTNET_INSTALL_DIR
            }
        }

        $candidateDir = Split-Path -Parent $candidateDir
        if ($candidateDir -eq $rootDir) {
            break
        }
    }

    # report the final set
    dotnet --list-sdks
}

function Update-Files {
    # install relevant SDKs
    Install-Sdks $job.source.directory
    # TODO: install workloads?

    Push-Location $env:DEPENDABOT_REPO_CONTENTS_PATH
    $baseCommitSha = git rev-parse HEAD
    Pop-Location

    $updaterTool = "$env:DEPENDABOT_NATIVE_HELPERS_PATH/nuget/NuGetUpdater/NuGetUpdater.Cli"
    & $updaterTool run `
        --job-path $env:DEPENDABOT_JOB_PATH `
        --repo-contents-path $env:DEPENDABOT_REPO_CONTENTS_PATH `
        --api-url $env:DEPENDABOT_API_URL `
        --job-id $env:DEPENDABOT_JOB_ID `
        --output-path $env:DEPENDABOT_OUTPUT_PATH `
        --base-commit-sha $baseCommitSha `
        --verbose
}

try {
    Switch ($args[0]) {
        "fetch_files" { Get-Files }
        "update_files" { Update-Files }
    }
}
catch {
    Write-Host $_
    Write-Host $_.Exception
    Write-Host $_.ScriptStackTrace
    exit 1
}
